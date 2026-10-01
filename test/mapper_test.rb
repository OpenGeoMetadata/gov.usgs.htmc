require 'minitest/autorun'
require 'csv'
require 'json'
require_relative '../mapper'

# Fixture rows are real rows from USGS's inventory, chosen for the cases they exercise
class MapperTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'historicaltopo.csv')
  ROWS = CSV.read(FIXTURE, headers: true, encoding: 'bom|utf-8').to_h { |row| [row['scan_id'], row.to_h] }

  def map(scan_id)
    Mapper.map(ROWS.fetch(scan_id))
  end

  def test_bright_angel_record
    record = map('314262')

    assert_equal 'usgs-htmc-314262', record['id']
    assert_equal 'USGS 1:48000-scale Quadrangle for Bright Angel, AZ 1906 (printed 1918)', record['dct_title_s']
    assert_equal ['Bright Angel'], record['dct_alternative_sm']
    assert_equal [
      'Scan of the 1906 edition of the Bright Angel, Arizona, topographic map at 1:48,000 scale ' \
      '(15 x 15 minute series), published by the U.S. Geological Survey. ' \
      'Surveyed in 1903; last revised in 1915; printed in 1918.',
      'Sheet size: 20.4 x 25.7 inches. Printed projection: not stated; horizontal datum: not stated. ' \
      'From the USGS Historical Topographic Map Collection.'
    ], record['dct_description_sm']
    assert_equal ['Geological Survey (U.S.)'], record['dct_creator_sm']
    assert_equal ['Geological Survey (U.S.)'], record['dct_publisher_sm']
    assert_equal '1906', record['dct_issued_s']
    assert_equal [1906], record['gbl_indexYear_im']
    assert_equal ['[1903 TO 1918]'], record['gbl_dateRange_drsim']
    assert_equal ['Coconino County, Arizona', 'Arizona'], record['dct_spatial_sm']
    assert_equal ['eng'], record['dct_language_sm']
    assert_equal ['Historical Topographic Maps', '15 x 15 minute'], record['dcat_keyword_sm']
    assert_equal 'POLYGON((-112 36,-112 36.25,-112.25 36.25,-112.25 36,-112 36))', record['locn_geometry']
    assert_equal 'ENVELOPE(-112.25, -112, 36.25, 36)', record['dcat_bbox']
    assert_equal '36.125,-112.125', record['dcat_centroid']
    assert_equal ['usgs-htmc'], record['pcdm_memberOf_sm']
    assert_equal [
      'https://www.sciencebase.gov/catalog/item/5a8a3d3ee4b00f54eb3e85f2',
      'urn:uuid:77047488-e079-db9c-8bba-e60f41bc5f30'
    ], record['dct_identifier_sm']
    assert_equal '2022-11-17T00:00:00Z', record['gbl_mdModified_dt']
  end

  def test_references
    refs = JSON.parse(map('314262')['dct_references_s'])
    base = 'https://prd-tnm.s3.amazonaws.com/StagedProducts/Maps/HistoricalTopo'

    assert_equal "#{base}/GeoTIFF/AZ/AZ_Bright%20Angel_314262_1906_48000_geo.tif", refs['https://github.com/cogeotiff/cog-spec']
    assert_equal [
      { 'url' => "#{base}/PDF/AZ/48000/AZ_Bright%20Angel_314262_1906_48000_geo.pdf", 'label' => 'GeoPDF (17.5 MB)' },
      { 'url' => "#{base}/GeoTIFF/AZ/AZ_Bright%20Angel_314262_1906_48000_geo.tif", 'label' => 'GeoTIFF' }
    ], refs['http://schema.org/downloadUrl']
    assert_equal 'https://thor-f5.er.usgs.gov/ngtoc/metadata/waf/maps/historicaltopo/pdf/AZ/48000/AZ_Bright_Angel_314262_1906_48000_geo.xml',
                 refs['http://www.opengis.net/cat/csw/csdgm']
    assert_equal 'https://www.sciencebase.gov/catalog/item/5a8a3d3ee4b00f54eb3e85f2', refs['http://schema.org/url']
    assert_equal "#{base}/PDF/AZ/48000/AZ_Bright%20Angel_314262_1906_48000_tn.jpg", refs['http://schema.org/thumbnailUrl']
  end

  # Corona and Vicinity's inventory row has "Unregistered" where its GeoTIFF URL belongs
  def test_placeholder_links_are_left_out
    refs = JSON.parse(map('363059')['dct_references_s'])

    refute refs.key?('https://github.com/cogeotiff/cog-spec')
    labels = refs['http://schema.org/downloadUrl'].map { |download| download['label'] }
    assert_equal ['GeoPDF (9.7 MB)'], labels
    refute_includes refs.to_json, 'Unregistered'
  end

  def test_geotiff_check
    assert Mapper.geotiff?(ROWS['314262'])
    refute Mapper.geotiff?(ROWS['363059'])
  end

  def test_title_has_no_printing_year_when_there_is_none_or_it_matches_the_edition
    assert_equal 'USGS 1:10000-scale Quadrangle for Adjuntas NE, PR 1947', map('361920')['dct_title_s']
    assert_equal 'USGS 1:25000-scale Quadrangle for Skagway B-4 NE, AK 1992', map('353820')['dct_title_s']
  end

  def test_other_federal_publishers
    record = map('315497')

    assert_equal ['United States. Army. Corps of Engineers', 'United States. Army Map Service'],
                 record['dct_creator_sm']
    assert_includes record['dct_description_sm'].first,
                    'published by the U.S. Army Corps of Engineers and the Army Map Service.'
  end

  def test_unknown_publisher_is_left_out
    record = map('303144')

    refute record.key?('dct_creator_sm')
    refute record.key?('dct_publisher_sm')
    refute_includes record['dct_description_sm'].first, 'published by'
  end

  def test_counties_are_left_out_when_the_map_covers_several_states
    assert_equal %w[Arizona Utah], map('315497')['dct_spatial_sm']
    assert_equal ['Alaska', 'British Columbia'], map('353820')['dct_spatial_sm']
  end

  def test_territory_places_and_spanish_language
    record = map('361920')

    assert_equal ['Utuado, Puerto Rico', 'Jayuya, Puerto Rico', 'Adjuntas, Puerto Rico', 'Puerto Rico'],
                 record['dct_spatial_sm']
    assert_equal ['spa'], record['dct_language_sm']
  end

  def test_county_equivalents
    assert_equal ['Aleutians West Census Area, Alaska', 'Alaska'], map('360510')['dct_spatial_sm']
    assert_equal ['Vermilion Parish, Louisiana', 'Louisiana'], map('331237')['dct_spatial_sm']
    assert_includes map('188838')['dct_spatial_sm'], 'Richmond, Virginia'
    assert_includes map('188838')['dct_spatial_sm'], 'Dinwiddie County, Virginia'
  end

  def test_map_without_state_list_or_grid_cell
    record = map('363059')

    assert_equal 'USGS 1:31680-scale Quadrangle for Corona and Vicinity, CA 1942', record['dct_title_s']
    assert_equal ['California'], record['dct_spatial_sm']
    assert_equal ['Historical Topographic Maps'], record['dcat_keyword_sm']
    refute_includes record['dct_description_sm'].first, 'series'
  end

  def test_release_variations_and_printed_datum
    details = map('353820')['dct_description_sm'].last

    assert_includes details, 'Release: Provisional.'
    assert_includes details, 'Variations: woodland tint.'
    assert_includes map('360510')['dct_description_sm'].last, 'Variations: shaded relief.'
    assert_includes map('331237')['dct_description_sm'].last,
                    'Printed projection: Universal Transverse Mercator; horizontal datum: NAD83.'
  end

  def test_seven_digit_scan_id_and_multiple_publishers
    record = map('8030540')

    assert_equal 'usgs-htmc-8030540', record['id']
    assert_equal "USGS 1:24000-scale Quadrangle for Bennett's Pier, DE 1949", record['dct_title_s']
    assert_equal ['Geological Survey (U.S.)', 'United States. Department of Commerce'], record['dct_publisher_sm']
  end

  # Only typed relationships are kept: collection membership, but no generic "related to" links
  def test_records_have_no_generic_relations
    ROWS.each_key do |scan_id|
      record = map(scan_id)
      refute record.key?('dct_relation_sm'), "#{scan_id} has dct_relation_sm"
      assert_equal ['usgs-htmc'], record['pcdm_memberOf_sm']
    end
  end

  def test_every_record_has_the_required_fields
    ROWS.each_key do |scan_id|
      record = map(scan_id)
      %w[id dct_title_s gbl_resourceClass_sm dct_accessRights_s gbl_mdVersion_s locn_geometry].each do |field|
        assert record[field], "#{scan_id} is missing #{field}"
      end
    end
  end

  def test_sheet
    sheet = Mapper.sheet(ROWS['314262'])
    base = 'https://prd-tnm.s3.amazonaws.com/StagedProducts/Maps/HistoricalTopo'

    assert_equal 'Feature', sheet['type']
    assert_equal({ 'type' => 'Polygon',
                   'coordinates' => [[[-112, 36], [-112, 36.25], [-112.25, 36.25], [-112.25, 36], [-112, 36]]] },
                 sheet['geometry'])
    assert_equal({
                   'label' => 'Bright Angel 1906 (printed 1918)', 'title' => 'Bright Angel', 'datePub' => '1906',
                   'dateSurvey' => '1903', 'dateReprnt' => '1918', 'scale' => '1:48,000',
                   'publisher' => 'U.S. Geological Survey', 'available' => true, 'recId' => 'usgs-htmc-314262',
                   'websiteUrl' => 'https://www.sciencebase.gov/catalog/item/5a8a3d3ee4b00f54eb3e85f2',
                   'download' => "#{base}/GeoTIFF/AZ/AZ_Bright%20Angel_314262_1906_48000_geo.tif",
                   'thumbUrl' => "#{base}/PDF/AZ/48000/AZ_Bright%20Angel_314262_1906_48000_tn.jpg"
                 }, sheet['properties'])
  end

  def test_sheet_without_a_later_printing_or_a_known_publisher
    adjuntas = Mapper.sheet(ROWS['361920'])['properties']

    assert_equal 'Adjuntas NE 1947', adjuntas['label']
    refute adjuntas.key?('dateReprnt')
    # Printed in the year of its edition
    refute Mapper.sheet(ROWS['353820'])['properties'].key?('dateReprnt')
    refute Mapper.sheet(ROWS['303144'])['properties'].key?('publisher')
    assert_equal 'U.S. Army Corps of Engineers; Army Map Service',
                 Mapper.sheet(ROWS['315497'])['properties']['publisher']
  end

  def test_index_map_states
    assert_equal %w[AZ UT], Mapper.new(ROWS['315497']).index_map_states
    # British Columbia gets no index map
    assert_equal ['AK'], Mapper.new(ROWS['353820']).index_map_states
    # No state_list, so just the primary state
    assert_equal ['CA'], Mapper.new(ROWS['363059']).index_map_states
  end

  def test_geojson_geometry
    assert_equal({ 'type' => 'MultiPolygon',
                   'coordinates' => [[[[1, 2], [3, 4.5], [1, 2]]], [[[5, 6], [7, 8], [5, 6]]]] },
                 Mapper.geojson_geometry('MULTIPOLYGON(((1 2,3 4.5,1 2)),((5 6,7 8,5 6)))'))
    assert_equal [[[-89.375, 43], [-89.25, 43]]],
                 Mapper.geojson_geometry('POLYGON((-89.37500000 43.00000000,-89.25 43))')['coordinates']
    assert_nil Mapper.geojson_geometry('POINT(1 2)')
    assert_nil Mapper.geojson_geometry(nil)
  end

  def test_index_map_record
    url = 'https://example.com/usgs-htmc-index-az-48000.geojson'
    record = Mapper.index_map(state: 'AZ', scale: '48000', maps: 4, sheets: 2, west: -112.25, east: -111.75,
                              north: 36.25, south: 36.0, first_year: 1903, last_year: 1907, modified: '2022-11-17',
                              url: url, bytes: 2_345)

    assert_equal 'usgs-htmc-index-az-48000', record['id']
    assert_equal 'Index to USGS 1:48000-scale Quadrangles of Arizona', record['dct_title_s']
    assert_equal 'Outlines of the USGS topographic maps at 1:48,000 scale that cover Arizona, from the Historical ' \
                 'Topographic Map Collection: 4 maps of 2 sheets, dated 1903 to 1907.',
                 record['dct_description_sm'].first
    assert_equal ['1903-1907'], record['dct_temporal_sm']
    assert_equal [1903, 1904, 1905, 1906, 1907], record['gbl_indexYear_im']
    assert_equal ['[1903 TO 1907]'], record['gbl_dateRange_drsim']
    assert_equal ['Arizona'], record['dct_spatial_sm']
    assert_equal ['Maps'], record['gbl_resourceClass_sm']
    assert_equal ['Index maps', 'Topographic maps'], record['gbl_resourceType_sm']
    assert_equal 'GeoJSON', record['dct_format_s']
    assert_equal 'ENVELOPE(-112.25, -111.75, 36.25, 36)', record['dcat_bbox']
    assert_equal ['usgs-htmc'], record['pcdm_memberOf_sm']
    assert_equal ['https://creativecommons.org/publicdomain/zero/1.0/'], record['dct_license_sm']
    assert_equal '2022-11-17T00:00:00Z', record['gbl_mdModified_dt']
    assert_equal({ 'https://openindexmaps.org' => url,
                   'http://schema.org/downloadUrl' => [{ 'url' => url, 'label' => 'GeoJSON (3 KB)' }] },
                 JSON.parse(record['dct_references_s']))
  end

  def test_index_map_record_for_maps_of_a_single_year
    record = Mapper.index_map(state: 'DE', scale: '24000', maps: 2, sheets: 2, west: -75.375, east: -75.125,
                              north: 39.125, south: 39.0, first_year: 1949, last_year: 1949, modified: '2022-11-17',
                              url: 'https://example.com/usgs-htmc-index-de-24000.geojson', bytes: 8_500_000)

    assert_match(/Collection: 2 maps of 2 sheets, dated 1949\.\z/, record['dct_description_sm'].first)
    assert_equal ['1949'], record['dct_temporal_sm']
    assert_equal 'GeoJSON (8.5 MB)', JSON.parse(record['dct_references_s'])['http://schema.org/downloadUrl'][0]['label']
  end

  def test_collection_record
    record = Mapper.collection(west: 134.5, east: -64.5, north: 71.5, south: -14.5, first_year: 1879, last_year: 2006,
                               modified: '2026-09-30', inventory_url: 'https://example.com/historicaltopo.zip')

    assert_equal 'usgs-htmc', record['id']
    assert_equal ['Collections'], record['gbl_resourceClass_sm']
    assert_equal 'ENVELOPE(134.5, -64.5, 71.5, -14.5)', record['dcat_bbox']
    assert_equal ['[1879 TO 2006]'], record['gbl_dateRange_drsim']
    assert_equal 128, record['gbl_indexYear_im'].size
    assert_equal 'https://example.com/historicaltopo.zip',
                 JSON.parse(record['dct_references_s'])['http://schema.org/downloadUrl'].first['url']
  end
end
