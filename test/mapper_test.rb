require 'minitest/autorun'
require 'csv'
require 'json'
require_relative '../mapper'

# Fixture rows are real rows from USGS's inventory, chosen for the cases they exercise
class MapperTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'historicaltopo.csv')
  ROWS = CSV.read(FIXTURE, headers: true, encoding: 'bom|utf-8').to_h { |row| [row['scan_id'], row.to_h] }

  def map(scan_id, **options)
    Mapper.map(ROWS.fetch(scan_id), **options)
  end

  def test_bright_angel_record
    record = map('314262', related_ids: %w[usgs-htmc-314255 usgs-htmc-314261])

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
    assert_equal %w[usgs-htmc-314255 usgs-htmc-314261], record['dct_relation_sm']
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

  def test_relations_are_left_out_when_there_are_none
    refute map('363059').key?('dct_relation_sm')
  end

  def test_every_record_has_the_required_fields
    ROWS.each_key do |scan_id|
      record = map(scan_id)
      %w[id dct_title_s gbl_resourceClass_sm dct_accessRights_s gbl_mdVersion_s locn_geometry].each do |field|
        assert record[field], "#{scan_id} is missing #{field}"
      end
    end
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
