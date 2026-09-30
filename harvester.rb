require 'date'
require 'fileutils'
require 'json'
require 'net/http'
require 'set'
require_relative 'extent'
require_relative 'inventory'
require_relative 'mapper'

# Regenerates the Aardvark records in metadata-aardvark/htmc/ from USGS's nightly inventory of the
# Historical Topographic Map Collection, and logs maps that leave the inventory in withdrawn.json.
#
# The inventory lists every map every night, so there is no incremental state to keep: each run rebuilds
# every record and writes only the files whose contents changed, and an unchanged inventory leaves the
# repository untouched.
class Harvester
  INVENTORY_URL = 'https://prd-tnm.s3.amazonaws.com/StagedProducts/Maps/Metadata/historicaltopo.zip'
  DOWNLOAD_PATH = 'tmp/historicaltopo.zip'

  # Default paths for the production repository
  METADATA_DIR = 'metadata-aardvark/htmc'
  WITHDRAWN_FILE = 'withdrawn.json'

  WITHDRAWALS_SCHEMA = 'https://opengeometadata.org/schema/ogm-withdrawals-1.0.json'

  # Refuse to withdraw anything if the inventory shrinks by more than this fraction in one run, so that a
  # truncated or broken inventory can't empty the repository. Rerun with FORCE=1 when the drop is real.
  MAX_SHRINK = 0.02

  class Error < StandardError; end

  # What the first pass over the inventory learns: every id, which scan each product is on, which maps
  # share a GNIS cell, and the collection's overall extent, years and modification date
  Index = Struct.new(:ids, :uuids, :cells, :extent, :first_year, :last_year, :modified)

  def self.run(**options)
    new(**options).run
  end

  attr_reader :source, :metadata_dir, :withdrawn_file, :dry_run, :force, :max_shrink, :today, :log

  def initialize(source: nil, metadata_dir: METADATA_DIR, withdrawn_file: WITHDRAWN_FILE, dry_run: false,
                 force: false, max_shrink: MAX_SHRINK, today: Date.today, log: $stdout)
    @source = source
    @metadata_dir = metadata_dir
    @withdrawn_file = withdrawn_file
    @dry_run = dry_run
    @force = force
    @max_shrink = max_shrink
    @today = today
    @log = log
  end

  # @return [Hash] counts of what the run did
  def run
    inventory = Inventory.new(source || download)
    index = build_index(inventory)
    check_complete(inventory, index)
    existing = existing_records
    check_shrinkage(existing.size, index.ids.size)

    counts = Hash.new(0)
    inventory.each_row { |row| counts[write_record(row, index)] += 1 }
    counts[:collection] = write_json(collection_path, collection_record(index))
    counts.merge!(withdraw(existing.keys - index.ids.to_a, existing, index))

    report(inventory, counts)
    counts
  end

  private

  def download
    log.puts "Downloading #{INVENTORY_URL}"
    FileUtils.mkdir_p(File.dirname(DOWNLOAD_PATH))
    uri = URI(INVENTORY_URL)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(Net::HTTP::Get.new(uri)) do |response|
        raise Error, "Download failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

        File.open(DOWNLOAD_PATH, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
      end
    end
    DOWNLOAD_PATH
  end

  def build_index(inventory)
    index = Index.new(Set.new, {}, Hash.new { |cells, cell| cells[cell] = [] }, Extent.new)
    inventory.each_row do |row|
      scan_id = row['scan_id'].to_s.strip
      raise Error, "A row in the inventory has no scan_id: #{row.inspect}" if scan_id.empty?

      id = Mapper.record_id(scan_id)
      raise Error, "scan_id #{scan_id} appears more than once in the inventory" unless index.ids.add?(id)

      add_to_index(index, row, id, scan_id)
    end
    index.cells.each_value(&:sort!)
    index
  end

  def add_to_index(index, row, id, scan_id)
    uuid = row['product_inventory_uuid'].to_s.strip
    index.uuids[uuid] = id unless uuid.empty?

    # -1 is the inventory's placeholder for a map without a matching GNIS cell
    cell = row['gnis_cell_id'].to_s.strip
    index.cells[cell] << scan_id.to_i unless cell.empty? || cell == '-1'

    begin
      index.extent.add(*%w[westbc eastbc northbc southbc].map { |key| Float(row[key]) })
    rescue ArgumentError, TypeError
      raise Error, "scan_id #{scan_id} has an unreadable bounding box"
    end
    year = row['date_on_map'].to_i
    index.first_year = [index.first_year, year].compact.min if year.positive?
    index.last_year = [index.last_year, year].compact.max if year.positive?
    index.modified = [index.modified, row['metadata_date'].to_s.strip].compact.max
  end

  # A download cut short can still unzip into a shorter CSV, so check the row count against the report
  def check_complete(inventory, index)
    raise Error, 'The inventory lists no maps' if index.ids.empty?
    return if inventory.total.nil? || inventory.total == index.ids.size

    raise Error, "The inventory's report counts #{inventory.total} maps, but its CSV has #{index.ids.size}"
  end

  def check_shrinkage(existing_count, present_count)
    return if force || existing_count.zero? || present_count >= existing_count * (1 - max_shrink)

    raise Error, "The inventory lists #{present_count} maps, down from #{existing_count} records here: more " \
                 "than #{(max_shrink * 100).round}% fewer. Nothing was changed; rerun with FORCE=1 if the drop is real."
  end

  # Records are named by id, in directories bucketed by the thousands of their scan_id, which keeps
  # every directory under GitHub's 1,000-entry listing limit
  def record_path(scan_id)
    File.join(metadata_dir, (scan_id.to_i / 1000).to_s, "#{Mapper.record_id(scan_id)}.json")
  end

  def collection_path
    File.join(metadata_dir, "#{Mapper::COLLECTION_ID}.json")
  end

  # Every record currently in the repository, by id
  def existing_records
    Dir.glob(File.join(metadata_dir, '*', "#{Mapper::ID_PREFIX}*.json")).to_h { |path| [File.basename(path, '.json'), path] }
  end

  def write_record(row, index)
    scan_id = row['scan_id'].to_s.strip
    related = index.cells.fetch(row['gnis_cell_id'].to_s.strip, []) - [scan_id.to_i]
    record = Mapper.map(row, related_ids: related.map { |related_id| Mapper.record_id(related_id) })
    write_json(record_path(scan_id), record)
  end

  def collection_record(index)
    west, east = index.extent.longitudes
    Mapper.collection(
      west: west, east: east, north: index.extent.north, south: index.extent.south,
      first_year: index.first_year, last_year: index.last_year, modified: index.modified,
      inventory_url: INVENTORY_URL
    )
  end

  # Writes the file only when its contents change, so unchanged records don't show up in git
  # @return [Symbol] :created, :updated, or :unchanged
  def write_json(path, data)
    content = "#{JSON.pretty_generate(data)}\n"
    exists = File.exist?(path)
    return :unchanged if exists && File.read(path, mode: 'r:bom|utf-8') == content

    unless dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content, mode: 'w:utf-8')
    end
    exists ? :updated : :created
  end

  # Maps that left the inventory are deleted and logged in withdrawn.json, following the proposed
  # OpenGeoMetadata withdrawal convention: deleting a file alone doesn't tell harvesters to delete the
  # record. A map whose product reappears under a new scan_id was rescanned, so its entry says what
  # replaced it. Entries are only ever removed for maps that have come back.
  def withdraw(removed, existing, index)
    withdrawals = read_withdrawals
    entries = withdrawals['withdrawn']
    republished = entries.select { |entry| index.ids.include?(entry['id']) }
    entries -= republished

    superseded = 0
    removed.sort_by { |id| id.delete_prefix(Mapper::ID_PREFIX).to_i }.each do |id|
      replacement = replacement_for(existing[id], index)
      superseded += 1 if replacement
      entries = entries.reject { |entry| entry['id'] == id } << withdrawal(id, replacement)
      File.delete(existing[id]) unless dry_run
    end

    if !dry_run && (removed.any? || republished.any?)
      remove_empty_directories
      content = JSON.pretty_generate(withdrawals.merge('withdrawn' => entries))
      File.write(withdrawn_file, "#{content}\n", mode: 'w:utf-8')
    end
    { withdrawn: removed.size, superseded: superseded, republished: republished.size }
  end

  def read_withdrawals
    unless File.exist?(withdrawn_file)
      return { '$schema' => WITHDRAWALS_SCHEMA, 'ogm_version' => '1.0', 'withdrawn' => [] }
    end

    JSON.parse(File.read(withdrawn_file, mode: 'r:bom|utf-8'))
  end

  def withdrawal(id, replacement)
    return { 'id' => id, 'date' => today.iso8601, 'reason' => 'upstream-removed' } unless replacement

    { 'id' => id, 'date' => today.iso8601, 'reason' => 'superseded',
      'note' => 'USGS rescanned this map; the new scan has its own record.', 'is_replaced_by' => [replacement] }
  end

  # The record now carrying the removed record's product, if the product is still in the inventory
  def replacement_for(path, index)
    identifiers = JSON.parse(File.read(path, mode: 'r:bom|utf-8'))['dct_identifier_sm'] || []
    uuid = identifiers.find { |identifier| identifier.start_with?('urn:uuid:') }&.delete_prefix('urn:uuid:')
    uuid && index.uuids[uuid]
  end

  def remove_empty_directories
    Dir.glob(File.join(metadata_dir, '*/')).each { |dir| Dir.rmdir(dir) if Dir.empty?(dir) }
  end

  def report(inventory, counts)
    maps = counts[:created] + counts[:updated] + counts[:unchanged]
    log.puts "Inventory of #{inventory.date || 'unknown date'}: #{maps} maps"
    log.puts "Records: #{counts[:created]} created, #{counts[:updated]} updated, #{counts[:unchanged]} unchanged; " \
             "collection record #{counts[:collection]}"
    log.puts "Withdrawn: #{counts[:withdrawn]} (#{counts[:superseded]} superseded by a rescan); " \
             "republished: #{counts[:republished]}"
    log.puts 'Dry run: nothing was written' if dry_run
  end
end

if __FILE__ == $0
  begin
    Harvester.run(source: ENV['SOURCE'], dry_run: !ENV['DRY_RUN'].to_s.empty?, force: !ENV['FORCE'].to_s.empty?)
  rescue Harvester::Error, Inventory::Error => e
    warn "Harvest stopped: #{e.message}"
    exit 1
  end
end
