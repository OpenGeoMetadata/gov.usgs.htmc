require 'minitest/autorun'
require 'csv'
require 'json'
require_relative '../index_map'

class IndexMapTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'historicaltopo.csv')
  ROWS = CSV.read(FIXTURE, headers: true, encoding: 'bom|utf-8').to_h { |row| [row['scan_id'], row.to_h] }

  def index_maps(*rows)
    {}.tap { |index_maps| rows.each { |row| IndexMap.add(index_maps, row) } }
  end

  def test_one_index_map_for_each_state_and_scale
    index_maps = index_maps(*ROWS.values_at('314262', '314261', '315497', '360510'))

    assert_equal %w[usgs-htmc-index-ak-250000 usgs-htmc-index-az-250000 usgs-htmc-index-az-48000
                    usgs-htmc-index-ut-250000], index_maps.keys.sort
    assert_equal 'AZ', index_maps['usgs-htmc-index-az-48000'].state
    assert_equal '48000', index_maps['usgs-htmc-index-az-48000'].scale
  end

  # Bright Angel's three printings share a sheet, and Vishnu is the next sheet east
  def test_record_summarizes_the_maps
    index_map = index_maps(*ROWS.values_at('314262', '314261', '314255', '314292')).fetch('usgs-htmc-index-az-48000')
    record = index_map.record('https://example.com/usgs-htmc-index-az-48000.geojson', 2_345)

    assert_equal 2, index_map.sheets
    assert_match(/Collection: 4 maps of 2 sheets, dated 1903 to 1907\.\z/, record['dct_description_sm'].first)
    assert_equal 'ENVELOPE(-112.25, -111.75, 36.25, 36)', record['dcat_bbox']
    assert_equal '2022-11-17T00:00:00Z', record['gbl_mdModified_dt']
  end

  # Adak is just east of the antimeridian; a map of Attu, just west of it, makes the index map cross it
  def test_extent_crosses_the_antimeridian_when_that_is_narrower
    attu = ROWS['360510'].merge('scan_id' => '1', 'westbc' => '172', 'eastbc' => '174', 'northbc' => '53',
                                'southbc' => '52', 'geom_wkt' => 'POLYGON((174 52,174 53,172 53,172 52,174 52))')
    index_map = index_maps(ROWS['360510'], attu).fetch('usgs-htmc-index-ak-250000')

    assert_equal 'ENVELOPE(172, -176, 53, 51.25)', index_map.record('https://example.com/a.geojson', 1)['dcat_bbox']
  end

  def test_geojson_is_a_feature_collection_of_sheets
    index_map = index_maps(ROWS['314262']).fetch('usgs-htmc-index-az-48000')
    geojson = JSON.parse(index_map.geojson)

    assert_equal 'FeatureCollection', geojson['type']
    assert_equal [Mapper.sheet(ROWS['314262'])], geojson['features']
    assert index_map.geojson.end_with?("\n]}\n")
  end
end
