require 'minitest/autorun'
require 'csv'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require_relative '../harvester'

class HarvesterTest < Minitest::Test
  FIXTURES = File.join(__dir__, 'fixtures')
  TABLE = CSV.read(File.join(FIXTURES, 'historicaltopo.csv'), headers: true, encoding: 'bom|utf-8')
  HEADERS = TABLE.headers
  ROWS = TABLE.map(&:to_h)
  TODAY = Date.new(2026, 10, 1)

  def setup
    @tmp_dir = Dir.mktmpdir
    @metadata_dir = File.join(@tmp_dir, 'metadata-aardvark', 'htmc')
    @withdrawn_file = File.join(@tmp_dir, 'withdrawn.json')
    @sources = 0
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
  end

  # An inventory directory holding the given rows, with a report counting `total` maps
  def inventory(rows = ROWS, total: rows.size)
    dir = File.join(@tmp_dir, "inventory-#{@sources += 1}")
    FileUtils.mkdir_p(dir)
    CSV.open(File.join(dir, 'historicaltopo.csv'), 'w', write_headers: true, headers: HEADERS) do |csv|
      rows.each { |row| csv << row.values_at(*HEADERS) }
    end
    File.write(File.join(dir, 'historicaltopo.txt'),
               "Summary of Report historicaltopo\n\nTotal Files  | #{total}\nLast Updated | 2026-09-30\n")
    dir
  end

  def harvest(source, **options)
    Harvester.run(source: source, metadata_dir: @metadata_dir, withdrawn_file: @withdrawn_file, today: TODAY,
                  log: StringIO.new, **options)
  end

  def record(scan_id)
    JSON.parse(File.read(File.join(@metadata_dir, (scan_id / 1000).to_s, "usgs-htmc-#{scan_id}.json")))
  end

  def withdrawals
    JSON.parse(File.read(@withdrawn_file))['withdrawn']
  end

  def without(scan_id)
    ROWS.reject { |row| row['scan_id'] == scan_id.to_s }
  end

  def test_writes_records_bucketed_by_scan_id
    counts = harvest(inventory)

    assert_equal 12, counts[:created]
    assert File.exist?(File.join(@metadata_dir, '314', 'usgs-htmc-314262.json'))
    assert File.exist?(File.join(@metadata_dir, '8030', 'usgs-htmc-8030540.json'))
    assert_equal :created, counts[:collection]
    assert File.exist?(File.join(@metadata_dir, 'usgs-htmc.json'))
    refute File.exist?(@withdrawn_file), 'nothing was withdrawn, so there should be no log'
  end

  def test_files_are_pretty_printed_utf8_with_a_trailing_newline
    harvest(inventory)
    content = File.read(File.join(@metadata_dir, '361', 'usgs-htmc-361920.json'), mode: 'r:utf-8')

    assert content.start_with?("{\n  \"id\": \"usgs-htmc-361920\",")
    assert content.end_with?("}\n")
  end

  def test_relations_link_the_maps_of_a_cell
    harvest(inventory)

    assert_equal %w[usgs-htmc-314255 usgs-htmc-314261], record(314_262)['dct_relation_sm']
    assert_equal %w[usgs-htmc-314255 usgs-htmc-314262], record(314_261)['dct_relation_sm']
    refute record(363_059).key?('dct_relation_sm')
  end

  def test_collection_record_summarizes_the_inventory
    harvest(inventory)
    collection = JSON.parse(File.read(File.join(@metadata_dir, 'usgs-htmc.json')))

    assert_equal ['[1897 TO 1994]'], collection['gbl_dateRange_drsim']
    # The latest metadata_date of any map (Corona and Vicinity's)
    assert_equal '2025-01-30T00:00:00Z', collection['gbl_mdModified_dt']
  end

  def test_second_run_changes_nothing
    source = inventory
    harvest(source)
    counts = harvest(source)

    assert_equal 0, counts[:created]
    assert_equal 0, counts[:updated]
    assert_equal 12, counts[:unchanged]
    assert_equal :unchanged, counts[:collection]
  end

  def test_changed_row_updates_its_record
    harvest(inventory)
    rows = ROWS.map { |row| row['scan_id'] == '303144' ? row.merge('map_name' => 'Arkadelphia North') : row }
    counts = harvest(inventory(rows))

    assert_equal 1, counts[:updated]
    assert_equal ['Arkadelphia North'], record(303_144)['dct_alternative_sm']
  end

  def test_withdraws_maps_that_leave_the_inventory
    harvest(inventory)
    counts = harvest(inventory(without(303_144)), max_shrink: 1.0)

    assert_equal 1, counts[:withdrawn]
    refute File.exist?(File.join(@metadata_dir, '303', 'usgs-htmc-303144.json'))
    refute Dir.exist?(File.join(@metadata_dir, '303')), 'an emptied bucket should be removed'
    log = JSON.parse(File.read(@withdrawn_file))
    assert_equal 'https://opengeometadata.org/schema/ogm-withdrawals-1.0.json', log['$schema']
    assert_equal '1.0', log['ogm_version']
    assert_equal [{ 'id' => 'usgs-htmc-303144', 'date' => '2026-10-01', 'reason' => 'upstream-removed' }],
                 log['withdrawn']
  end

  def test_rescanned_map_is_superseded
    harvest(inventory)
    rescanned = ROWS.map { |row| row['scan_id'] == '303144' ? row.merge('scan_id' => '999999') : row }
    counts = harvest(inventory(rescanned), max_shrink: 1.0)

    assert_equal 1, counts[:created]
    assert_equal 1, counts[:superseded]
    entry = withdrawals.first
    assert_equal 'usgs-htmc-303144', entry['id']
    assert_equal 'superseded', entry['reason']
    assert_equal ['usgs-htmc-999999'], entry['is_replaced_by']
  end

  def test_republished_map_leaves_the_log
    harvest(inventory)
    harvest(inventory(without(303_144)), max_shrink: 1.0)
    counts = harvest(inventory, max_shrink: 1.0)

    assert_equal 1, counts[:republished]
    assert_empty withdrawals
    assert record(303_144)
  end

  def test_refuses_to_withdraw_after_a_large_drop
    harvest(inventory)
    error = assert_raises(Harvester::Error) { harvest(inventory(ROWS.first(2))) }

    assert_match(/down from 12 records/, error.message)
    assert record(303_144), 'no records should be removed'
    refute File.exist?(@withdrawn_file)
  end

  def test_force_allows_a_large_drop
    harvest(inventory)
    counts = harvest(inventory(ROWS.first(2)), force: true)

    assert_equal 10, counts[:withdrawn]
  end

  def test_refuses_an_inventory_that_disagrees_with_its_report
    error = assert_raises(Harvester::Error) { harvest(inventory(ROWS, total: 13)) }

    assert_match(/counts 13 maps, but its CSV has 12/, error.message)
    refute Dir.exist?(@metadata_dir)
  end

  def test_refuses_a_repeated_scan_id
    assert_raises(Harvester::Error) { harvest(inventory(ROWS + [ROWS.first])) }
  end

  def test_dry_run_writes_nothing
    counts = harvest(inventory, dry_run: true)

    assert_equal 12, counts[:created]
    refute Dir.exist?(@metadata_dir)
  end

  def test_reads_the_inventory_from_a_zip
    skip 'zip is not installed' unless system('which zip > /dev/null 2>&1')

    zip = File.join(@tmp_dir, 'historicaltopo.zip')
    source = inventory
    system('zip', '-q', '-j', zip, File.join(source, 'historicaltopo.csv'), File.join(source, 'historicaltopo.txt'),
           exception: true)
    counts = harvest(zip)

    assert_equal 12, counts[:created]
  end
end
