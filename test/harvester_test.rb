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

  # The fixture's two San Francisco scans (302040 and 302041) are twins, which make one record, and
  # Corona and Vicinity (363059) has no GeoTIFF, so it makes none
  RECORDS = ROWS.size - 2

  # Only a state and scale with at least two sheets gets an index map. Bright Angel's three printings and its
  # neighbor Vishnu make Arizona's 1:48,000 index map, and Grand Canyon and Marble Canyon, which both cover
  # Utah too, make Arizona's and Utah's 1:250,000 index maps.
  INDEX_MAPS = 3
  INDEX_MAP_URL = 'https://example.com/index-maps/htmc'

  def setup
    @tmp_dir = Dir.mktmpdir
    @metadata_dir = File.join(@tmp_dir, 'metadata-aardvark', 'htmc')
    @index_map_dir = File.join(@tmp_dir, 'index-maps', 'htmc')
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
    Harvester.run(source: source, metadata_dir: @metadata_dir, index_map_dir: @index_map_dir,
                  index_map_url: INDEX_MAP_URL, withdrawn_file: @withdrawn_file, today: TODAY, log: StringIO.new,
                  **options)
  end

  def record_path(scan_id)
    File.join(@metadata_dir, (scan_id / 1000).to_s, "usgs-htmc-#{scan_id}.json")
  end

  def record(scan_id)
    JSON.parse(File.read(record_path(scan_id)))
  end

  def index_map_record_path(id)
    File.join(@metadata_dir, 'index-maps', "#{id}.json")
  end

  def index_map_path(id)
    File.join(@index_map_dir, "#{id}.geojson")
  end

  def index_map_sheets(id)
    JSON.parse(File.read(index_map_path(id)))['features']
  end

  # The records of the maps an index map outlines, in the order it draws them
  def index_map_records(id)
    index_map_sheets(id).map { |sheet| sheet['properties']['recId'] }
  end

  def withdrawals
    JSON.parse(File.read(@withdrawn_file))['withdrawn']
  end

  def without(scan_id)
    ROWS.reject { |row| row['scan_id'] == scan_id.to_s }
  end

  def test_writes_records_bucketed_by_scan_id
    counts = harvest(inventory)

    assert_equal RECORDS, counts[:created]
    assert File.exist?(record_path(314_262))
    assert File.exist?(record_path(8_030_540))
    assert_equal :created, counts[:collection]
    assert File.exist?(File.join(@metadata_dir, 'usgs-htmc.json'))
    refute File.exist?(@withdrawn_file), 'nothing was withdrawn, so there should be no log'
  end

  def test_files_are_pretty_printed_utf8_with_a_trailing_newline
    harvest(inventory)
    content = File.read(record_path(361_920), mode: 'r:utf-8')

    assert content.start_with?("{\n  \"id\": \"usgs-htmc-361920\",")
    assert content.end_with?("}\n")
  end

  # The two scans differ only in their sheet sizes and files, which a catalog can't tell apart
  def test_keeps_only_the_later_scan_of_identical_twins
    counts = harvest(inventory)

    assert_equal 1, counts[:skipped]
    assert File.exist?(record_path(302_041))
    refute File.exist?(record_path(302_040))
  end

  def test_maps_that_differ_in_description_are_not_twins
    rows = ROWS.map { |row| row['scan_id'] == '302041' ? row.merge('imprint_year' => '1980') : row }
    counts = harvest(inventory(rows))

    assert_equal 0, counts[:skipped]
    assert File.exist?(record_path(302_040))
    assert File.exist?(record_path(302_041))
  end

  def test_published_map_that_gains_a_later_twin_is_withdrawn_as_a_duplicate
    harvest(inventory(without(302_041)))
    assert File.exist?(record_path(302_040))

    counts = harvest(inventory)

    assert_equal 1, counts[:duplicates]
    refute File.exist?(record_path(302_040))
    assert File.exist?(record_path(302_041))
    entry = withdrawals.first
    assert_equal 'usgs-htmc-302040', entry['id']
    assert_equal 'duplicate', entry['reason']
    assert_equal ['usgs-htmc-302041'], entry['is_replaced_by']
  end

  def test_skips_maps_without_a_geotiff
    counts = harvest(inventory)

    assert_equal 1, counts[:no_geotiff]
    refute File.exist?(record_path(363_059))
  end

  def test_published_map_that_loses_its_geotiff_is_withdrawn
    harvest(inventory)
    rows = ROWS.map { |row| row['scan_id'] == '303144' ? row.merge('geotiff_url' => 'Unregistered') : row }
    counts = harvest(inventory(rows), max_shrink: 1.0)

    assert_equal 1, counts[:without_geotiff]
    refute File.exist?(record_path(303_144))
    assert_equal({ 'id' => 'usgs-htmc-303144', 'date' => '2026-10-01', 'reason' => 'quality',
                   'note' => "USGS's inventory no longer lists a GeoTIFF for this map." }, withdrawals.first)
  end

  # When the later scan has no GeoTIFF, the earlier one stands for the map instead
  def test_twin_with_a_geotiff_stands_in_for_one_without
    rows = ROWS.map { |row| row['scan_id'] == '302041' ? row.merge('geotiff_url' => 'Unregistered') : row }
    counts = harvest(inventory(rows))

    assert_equal 0, counts[:skipped]
    assert File.exist?(record_path(302_040))
    refute File.exist?(record_path(302_041))
  end

  def test_collection_record_summarizes_the_inventory
    harvest(inventory)
    collection = JSON.parse(File.read(File.join(@metadata_dir, 'usgs-htmc.json')))

    assert_equal ['[1897 TO 1994]'], collection['gbl_dateRange_drsim']
    # The latest metadata_date of any map (Corona and Vicinity's)
    assert_equal '2025-01-30T00:00:00Z', collection['gbl_mdModified_dt']
  end

  def test_writes_an_index_map_for_each_state_and_scale
    counts = harvest(inventory)

    assert_equal INDEX_MAPS, counts[:index_maps_created]
    id = 'usgs-htmc-index-az-48000'
    record = JSON.parse(File.read(index_map_record_path(id)))
    assert_equal id, record['id']
    assert_equal "#{INDEX_MAP_URL}/#{id}.geojson", JSON.parse(record['dct_references_s'])['https://openindexmaps.org']
    assert_equal ['usgs-htmc'], record['pcdm_memberOf_sm']
  end

  # The specification asks for one outline per edition. Ordered oldest first, viewers draw the latest on top.
  def test_editions_and_printings_of_a_sheet_are_stacked_latest_last
    harvest(inventory)
    sheets = index_map_sheets('usgs-htmc-index-az-48000')

    assert_equal %w[usgs-htmc-314255 usgs-htmc-314262 usgs-htmc-314261 usgs-htmc-314292],
                 index_map_records('usgs-htmc-index-az-48000')
    assert_equal ['Bright Angel 1903 (printed 1961)', 'Bright Angel 1906 (printed 1918)',
                  'Bright Angel 1906 (printed 1920)', 'Vishnu 1907 (printed 1919)'],
                 (sheets.map { |sheet| sheet['properties']['label'] })
    assert_equal 2, sheets.map { |sheet| sheet['geometry'] }.uniq.size
  end

  def test_maps_are_in_the_index_map_of_every_us_state_they_cover
    harvest(inventory)

    %w[usgs-htmc-index-az-250000 usgs-htmc-index-ut-250000].each do |id|
      assert_equal %w[usgs-htmc-315497 usgs-htmc-315534], index_map_records(id)
    end
  end

  # Arkadelphia is Alabama's only 1:24,000 map, and San Francisco's twins are California's only 1:100,000 sheet
  def test_a_single_sheet_gets_no_index_map
    harvest(inventory)

    refute File.exist?(index_map_path('usgs-htmc-index-al-24000'))
    refute File.exist?(index_map_record_path('usgs-htmc-index-ca-100000'))
    assert_equal INDEX_MAPS, Dir.glob(File.join(@index_map_dir, '*.geojson')).size
  end

  # A map without a GeoTIFF has no record, and neither does a twin of a later scan, so neither has a sheet
  def test_index_maps_outline_only_maps_with_records
    vishnu = ROWS.find { |row| row['scan_id'] == '314292' }
    rows = ROWS.map { |row| row['scan_id'] == '314261' ? row.merge('geotiff_url' => 'Unregistered') : row }
    harvest(inventory(rows + [vishnu.merge('scan_id' => '314291')]))

    assert_equal %w[usgs-htmc-314255 usgs-htmc-314262 usgs-htmc-314292], index_map_records('usgs-htmc-index-az-48000')
  end

  # One sheet to a line, so that a change to one map shows up in git as a change to one line
  def test_index_map_has_one_sheet_per_line
    harvest(inventory)
    lines = File.readlines(index_map_path('usgs-htmc-index-az-48000'), chomp: true)

    assert_equal '{"type":"FeatureCollection","features":[', lines.first
    assert_equal ']}', lines.last
    assert_equal 4, lines[1..-2].size
    lines[1..-2].each { |line| assert JSON.parse(line.chomp(',')) }
  end

  def test_changed_map_updates_its_index_maps
    harvest(inventory)
    rows = ROWS.map { |row| row['scan_id'] == '315534' ? row.merge('map_name' => 'Marble Gorge') : row }
    counts = harvest(inventory(rows))

    assert_equal 2, counts[:index_maps_updated]
    assert_equal 1, counts[:index_maps_unchanged]
    assert_equal 'Marble Gorge 1961', index_map_sheets('usgs-htmc-index-ut-250000').last['properties']['label']
  end

  # Without Vishnu, Arizona's 1:48,000 maps are all Bright Angel's, on one sheet
  def test_index_map_left_with_one_sheet_is_withdrawn_until_it_has_two_again
    harvest(inventory)
    counts = harvest(inventory(without(314_292)), max_shrink: 1.0)

    assert_equal 1, counts[:index_maps_withdrawn]
    refute File.exist?(index_map_path('usgs-htmc-index-az-48000'))
    refute File.exist?(index_map_record_path('usgs-htmc-index-az-48000'))
    assert_equal({ 'id' => 'usgs-htmc-index-az-48000', 'date' => '2026-10-01', 'reason' => 'upstream-removed',
                   'note' => 'Fewer than two of the sheets this index map outlined remain in the repository.' },
                 withdrawals.last)

    counts = harvest(inventory, max_shrink: 1.0)

    assert_equal 1, counts[:index_maps_republished]
    assert_empty withdrawals
    assert File.exist?(index_map_path('usgs-htmc-index-az-48000'))
  end

  def test_second_run_changes_nothing
    source = inventory
    harvest(source)
    counts = harvest(source)

    assert_equal 0, counts[:created]
    assert_equal 0, counts[:updated]
    assert_equal RECORDS, counts[:unchanged]
    assert_equal :unchanged, counts[:collection]
    assert_equal INDEX_MAPS, counts[:index_maps_unchanged]
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
    assert_equal 0, counts[:index_maps_withdrawn]
    refute File.exist?(record_path(303_144))
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

    assert_match(/down from #{RECORDS}/, error.message)
    assert record(303_144), 'no records should be removed'
    refute File.exist?(@withdrawn_file)
  end

  def test_force_allows_a_large_drop
    harvest(inventory)
    counts = harvest(inventory(ROWS.first(2)), force: true)

    assert_equal RECORDS - 2, counts[:withdrawn]
  end

  def test_refuses_an_inventory_that_disagrees_with_its_report
    error = assert_raises(Harvester::Error) { harvest(inventory(ROWS, total: ROWS.size + 1)) }

    assert_match(/counts #{ROWS.size + 1} maps, but its CSV has #{ROWS.size}/, error.message)
    refute Dir.exist?(@metadata_dir)
  end

  def test_refuses_a_repeated_scan_id
    assert_raises(Harvester::Error) { harvest(inventory(ROWS + [ROWS.first])) }
  end

  def test_dry_run_writes_nothing
    counts = harvest(inventory, dry_run: true)

    assert_equal RECORDS, counts[:created]
    assert_equal INDEX_MAPS, counts[:index_maps_created]
    refute Dir.exist?(@metadata_dir)
    refute Dir.exist?(@index_map_dir)
  end

  def test_reads_the_inventory_from_a_zip
    skip 'zip is not installed' unless system('which zip > /dev/null 2>&1')

    zip = File.join(@tmp_dir, 'historicaltopo.zip')
    source = inventory
    system('zip', '-q', '-j', zip, File.join(source, 'historicaltopo.csv'), File.join(source, 'historicaltopo.txt'),
           exception: true)
    counts = harvest(zip)

    assert_equal RECORDS, counts[:created]
  end
end
