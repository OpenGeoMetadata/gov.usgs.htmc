require 'date'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'set'
require_relative 'extent'
require_relative 'index_map'
require_relative 'inventory'
require_relative 'mapper'

# Regenerates the Aardvark records in metadata-aardvark/htmc/ from USGS's nightly inventory of the
# Historical Topographic Map Collection, along with an index map for each scale of map covering each state,
# and logs records that leave the repository in withdrawn.json.
#
# The inventory lists every map every night, so there is no incremental state to keep: each run rebuilds
# every record and writes only the files whose contents changed, and an unchanged inventory leaves the
# repository untouched.
class Harvester
  INVENTORY_URL = 'https://prd-tnm.s3.amazonaws.com/StagedProducts/Maps/Metadata/historicaltopo.zip'
  DOWNLOAD_PATH = 'tmp/historicaltopo.zip'

  # Default paths for the production repository. Index maps' GeoJSON is kept out of metadata-aardvark/ and
  # named .geojson, so that harvesters looking for records don't mistake it for one.
  METADATA_DIR = 'metadata-aardvark/htmc'
  INDEX_MAP_DIR = 'index-maps/htmc'
  WITHDRAWN_FILE = 'withdrawn.json'

  # Where the index map records say their GeoJSON is: INDEX_MAP_DIR, as GitHub serves it
  INDEX_MAP_URL = 'https://raw.githubusercontent.com/OpenGeoMetadata/gov.usgs.htmc/main/index-maps/htmc'

  WITHDRAWALS_SCHEMA = 'https://opengeometadata.org/schema/ogm-withdrawals-1.0.json'

  # Refuse to withdraw anything if a run would shrink the repository by more than this fraction, so that a
  # truncated or broken inventory can't empty it. Rerun with FORCE=1 when the drop is real.
  MAX_SHRINK = 0.02

  # Columns that describe one copy of a map rather than the map: which scan it is, the sheet it was printed
  # on, and the files and metadata made from it. Maps whose rows match in every other column are twins that
  # a catalog can't tell apart, so only the one with the latest scan becomes a record.
  COPY_COLUMNS = %w[
    scan_id product_inventory_uuid page_width_inches page_height_inches product_filename product_filesize
    product_url thumbnail_url geotiff_url metadata_url sciencebase_url metadata_date
  ].freeze

  class Error < StandardError; end

  # What the first pass over the inventory learns: every id, which scan each product is on, which scan of
  # each set of twins is kept, which maps have no GeoTIFF, and the collection's overall extent, years and
  # modification date
  Index = Struct.new(:ids, :uuids, :twins, :scan_keys, :kept, :unregistered, :extent, :first_year, :last_year,
                     :modified)

  def self.run(**options)
    new(**options).run
  end

  attr_reader :source, :metadata_dir, :index_map_dir, :index_map_url, :withdrawn_file, :dry_run, :force,
              :max_shrink, :today, :log

  def initialize(source: nil, metadata_dir: METADATA_DIR, index_map_dir: INDEX_MAP_DIR, index_map_url: INDEX_MAP_URL,
                 withdrawn_file: WITHDRAWN_FILE, dry_run: false, force: false, max_shrink: MAX_SHRINK,
                 today: Date.today, log: $stdout)
    @source = source
    @metadata_dir = metadata_dir
    @index_map_dir = index_map_dir
    @index_map_url = index_map_url.chomp('/')
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
    check_shrinkage(existing.size, index.kept.size)

    counts = Hash.new(0)
    index_maps = {}
    inventory.each_row do |row|
      status = write_record(row, index)
      counts[status] += 1
      IndexMap.add(index_maps, row) unless %i[no_geotiff skipped].include?(status)
    end
    counts[:collection] = write_json(collection_path, collection_record(index))
    # An index map is for finding a sheet among others, so a single sheet gets none
    index_maps.select! { |_id, index_map| index_map.sheets > 1 }
    index_maps.each_value { |index_map| counts[:"index_maps_#{write_index_map(index_map)}"] += 1 }
    counts.merge!(withdraw(removals(existing, index, index_maps), index.kept | index_maps.keys))

    report(inventory, index, counts)
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
    index = Index.new(Set.new, {}, {}, {}, nil, Set.new, Extent.new)
    inventory.each_row do |row|
      scan_id = row['scan_id'].to_s.strip
      raise Error, "A row in the inventory has no scan_id: #{row.inspect}" if scan_id.empty?

      id = Mapper.record_id(scan_id)
      raise Error, "scan_id #{scan_id} appears more than once in the inventory" unless index.ids.add?(id)

      add_to_index(index, row, scan_id.to_i)
    end
    index.kept = Set.new(index.twins.values.map { |scan| Mapper.record_id(scan) })
    index
  end

  def add_to_index(index, row, scan)
    uuid = row['product_inventory_uuid'].to_s.strip
    index.uuids[uuid] = scan unless uuid.empty?

    # A map without a GeoTIFF gets no record, so it can't stand in for its twins either
    key = twin_key(row)
    index.scan_keys[scan] = key
    if Mapper.geotiff?(row)
      index.twins[key] = [index.twins[key], scan].compact.max
    else
      index.unregistered << scan
    end

    begin
      index.extent.add(*%w[westbc eastbc northbc southbc].map { |column| Float(row[column]) })
    rescue ArgumentError, TypeError
      raise Error, "scan_id #{scan} has an unreadable bounding box"
    end
    year = row['date_on_map'].to_i
    index.first_year = [index.first_year, year].compact.min if year.positive?
    index.last_year = [index.last_year, year].compact.max if year.positive?
    index.modified = [index.modified, row['metadata_date'].to_s.strip].compact.max
  end

  # Twins share a key: a digest of every column but COPY_COLUMNS
  def twin_key(row)
    columns = row.except(*COPY_COLUMNS).sort.map { |column, value| "#{column}=#{value.to_s.strip}" }
    Digest::SHA256.digest(columns.join("\n"))
  end

  # The id of the record that stands for a scan: its own, or that of its latest twin with a GeoTIFF.
  # nil when neither it nor any twin has a GeoTIFF.
  def kept_id(index, scan)
    kept = index.twins[index.scan_keys.fetch(scan)]
    kept && Mapper.record_id(kept)
  end

  # A download cut short can still unzip into a shorter CSV, so check the row count against the report
  def check_complete(inventory, index)
    raise Error, 'The inventory lists no maps' if index.ids.empty?
    return if inventory.total.nil? || inventory.total == index.ids.size

    raise Error, "The inventory's report counts #{inventory.total} maps, but its CSV has #{index.ids.size}"
  end

  def check_shrinkage(existing_count, kept_count)
    return if force || existing_count.zero? || kept_count >= existing_count * (1 - max_shrink)

    raise Error, "This run would leave #{kept_count} records, down from #{existing_count}: more than " \
                 "#{(max_shrink * 100).round}% fewer. Nothing was changed; rerun with FORCE=1 if the drop is real."
  end

  # Records are named by id, in directories bucketed by the thousands of their scan_id, which keeps
  # every directory under GitHub's 1,000-entry listing limit
  def record_path(scan_id)
    File.join(metadata_dir, (scan_id.to_i / 1000).to_s, "#{Mapper.record_id(scan_id)}.json")
  end

  def collection_path
    File.join(metadata_dir, "#{Mapper::COLLECTION_ID}.json")
  end

  # Index map records sit together in a directory of their own, beside the scan_id buckets
  def index_map_record_path(id)
    File.join(metadata_dir, 'index-maps', "#{id}.json")
  end

  def index_map_path(id)
    File.join(index_map_dir, "#{id}.geojson")
  end

  # Every map's record currently in the repository, by id
  def existing_records
    Dir.glob(File.join(metadata_dir, '[0-9]*', "#{Mapper::ID_PREFIX}*.json")).to_h do |path|
      [File.basename(path, '.json'), path]
    end
  end

  # Every index map's record currently in the repository, by id
  def existing_index_maps
    Dir.glob(index_map_record_path("#{Mapper::INDEX_MAP_PREFIX}*")).to_h { |path| [File.basename(path, '.json'), path] }
  end

  # @return [Symbol] :created, :updated, or :unchanged; :no_geotiff for a map without a GeoTIFF, or
  #   :skipped for a map a later scan stands for
  def write_record(row, index)
    scan_id = row['scan_id'].to_s.strip
    return :no_geotiff if index.unregistered.include?(scan_id.to_i)
    return :skipped unless index.kept.include?(Mapper.record_id(scan_id))

    write_json(record_path(scan_id), Mapper.map(row))
  end

  def collection_record(index)
    west, east = index.extent.longitudes
    Mapper.collection(
      west: west, east: east, north: index.extent.north, south: index.extent.south,
      first_year: index.first_year, last_year: index.last_year, modified: index.modified,
      inventory_url: INVENTORY_URL
    )
  end

  # Writes an index map's GeoJSON, and the record that points to it
  # @return [Symbol] :created, :updated, or :unchanged, for whichever of the two changed most
  def write_index_map(index_map)
    geojson = index_map.geojson
    record = index_map.record("#{index_map_url}/#{File.basename(index_map_path(index_map.id))}", geojson.bytesize)
    statuses = [write_file(index_map_path(index_map.id), geojson),
                write_json(index_map_record_path(index_map.id), record)]
    %i[created updated unchanged].find { |status| statuses.include?(status) }
  end

  def write_json(path, data)
    write_file(path, "#{JSON.pretty_generate(data)}\n")
  end

  # Writes the file only when its contents change, so unchanged records don't show up in git
  # @return [Symbol] :created, :updated, or :unchanged
  def write_file(path, content)
    exists = File.exist?(path)
    return :unchanged if exists && File.read(path, mode: 'r:bom|utf-8') == content

    unless dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content, mode: 'w:utf-8')
    end
    exists ? :updated : :created
  end

  # The records leaving the repository, maps' first, each with its withdrawal entry and the files to delete.
  # An index map leaves once fewer than two sheets remain in it.
  def removals(existing, index, index_maps)
    maps = (existing.keys - index.kept.to_a).sort_by { |id| id.delete_prefix(Mapper::ID_PREFIX).to_i }.map do |id|
      [withdrawal(id, existing[id], index), [existing[id]]]
    end
    indexes = existing_index_maps.reject { |id, _path| index_maps.key?(id) }.sort.map do |id, path|
      entry = { 'id' => id, 'date' => today.iso8601, 'reason' => 'upstream-removed',
                'note' => 'Fewer than two of the sheets this index map outlined remain in the repository.' }
      [entry, [path, index_map_path(id)]]
    end
    maps + indexes
  end

  # Records that leave the repository are deleted and logged in withdrawn.json, following the proposed
  # OpenGeoMetadata withdrawal convention: deleting a file alone doesn't tell harvesters to delete the
  # record. Each entry says why, and what replaced the record if anything did. Entries are only ever
  # removed for records that have come back.
  # @param published [Set] the id of every record the repository now has
  def withdraw(removals, published)
    withdrawals = read_withdrawals
    republished, entries = withdrawals['withdrawn'].partition { |entry| published.include?(entry['id']) }

    removals.each do |entry, paths|
      entries = entries.reject { |other| other['id'] == entry['id'] } << entry
      paths.each { |path| File.delete(path) if File.exist?(path) } unless dry_run
    end

    if !dry_run && (removals.any? || republished.any?)
      remove_empty_directories
      content = JSON.pretty_generate(withdrawals.merge('withdrawn' => entries))
      File.write(withdrawn_file, "#{content}\n", mode: 'w:utf-8')
    end
    withdrawal_counts(removals.map(&:first), republished)
  end

  def withdrawal_counts(withdrawn, republished)
    index_map = ->(entry) { entry['id'].start_with?(Mapper::INDEX_MAP_PREFIX) }
    reasons = withdrawn.reject(&index_map).map { |entry| entry['reason'] }.tally
    { withdrawn: withdrawn.count { |entry| !index_map.call(entry) }, duplicates: reasons.fetch('duplicate', 0),
      without_geotiff: reasons.fetch('quality', 0), superseded: reasons.fetch('superseded', 0),
      republished: republished.count { |entry| !index_map.call(entry) },
      index_maps_withdrawn: withdrawn.count(&index_map), index_maps_republished: republished.count(&index_map) }
  end

  def read_withdrawals
    unless File.exist?(withdrawn_file)
      return { '$schema' => WITHDRAWALS_SCHEMA, 'ogm_version' => '1.0', 'withdrawn' => [] }
    end

    JSON.parse(File.read(withdrawn_file, mode: 'r:bom|utf-8'))
  end

  def withdrawal(id, path, index)
    entry = { 'id' => id, 'date' => today.iso8601 }
    scan = id.delete_prefix(Mapper::ID_PREFIX).to_i
    in_inventory = index.ids.include?(id)
    replacement = in_inventory ? kept_id(index, scan) : replacement_for(path, index)
    if in_inventory && index.unregistered.include?(scan)
      entry.merge!('reason' => 'quality', 'note' => "USGS's inventory no longer lists a GeoTIFF for this map.")
    elsif in_inventory
      # Still in the inventory, but a later scan now describes the same map
      entry.merge!('reason' => 'duplicate',
                   'note' => "USGS's inventory describes this map identically to a later scan.")
    elsif replacement
      entry.merge!('reason' => 'superseded', 'note' => 'USGS rescanned this map; the new scan has its own record.')
    else
      entry['reason'] = 'upstream-removed'
    end
    replacement ? entry.merge('is_replaced_by' => [replacement]) : entry
  end

  # The record that now carries the removed record's product, if the product is still in the inventory
  def replacement_for(path, index)
    identifiers = JSON.parse(File.read(path, mode: 'r:bom|utf-8'))['dct_identifier_sm'] || []
    uuid = identifiers.find { |identifier| identifier.start_with?('urn:uuid:') }&.delete_prefix('urn:uuid:')
    scan = uuid && index.uuids[uuid]
    scan && kept_id(index, scan)
  end

  def remove_empty_directories
    Dir.glob(File.join(metadata_dir, '*/')).each { |dir| Dir.rmdir(dir) if Dir.empty?(dir) }
  end

  def report(inventory, index, counts)
    log.puts "Inventory of #{inventory.date || 'unknown date'}: #{index.ids.size} maps"
    log.puts "Records: #{counts[:created]} created, #{counts[:updated]} updated, #{counts[:unchanged]} unchanged; " \
             "collection record #{counts[:collection]}"
    log.puts "Skipped: #{counts[:skipped]} twins of a later scan, #{counts[:no_geotiff]} maps without a GeoTIFF"
    log.puts "Withdrawn: #{counts[:withdrawn]} (#{counts[:duplicates]} duplicates, #{counts[:without_geotiff]} " \
             "without a GeoTIFF, #{counts[:superseded]} superseded by a rescan); republished: #{counts[:republished]}"
    log.puts "Index maps: #{counts[:index_maps_created]} created, #{counts[:index_maps_updated]} updated, " \
             "#{counts[:index_maps_unchanged]} unchanged; #{counts[:index_maps_withdrawn]} withdrawn, " \
             "#{counts[:index_maps_republished]} republished"
    log.puts 'Dry run: nothing was written' if dry_run
  end
end

if __FILE__ == $0
  begin
    Harvester.run(source: ENV['SOURCE'], dry_run: !ENV['DRY_RUN'].to_s.empty?, force: !ENV['FORCE'].to_s.empty?,
                  index_map_url: ENV['INDEX_MAP_URL'].to_s.empty? ? Harvester::INDEX_MAP_URL : ENV['INDEX_MAP_URL'])
  rescue Harvester::Error, Inventory::Error => e
    warn "Harvest stopped: #{e.message}"
    exit 1
  end
end
