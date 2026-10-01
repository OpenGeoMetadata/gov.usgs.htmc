require 'json'
require_relative 'places'

# Maps one row of USGS's inventory of the Historical Topographic Map Collection (HTMC) to an OGM
# Aardvark record, and builds the collection-level record every map is a member of. Also describes each
# map as a sheet of an OpenIndexMaps index map, and builds the records for those index maps.
class Mapper
  ID_PREFIX = 'usgs-htmc-'
  INDEX_MAP_PREFIX = "#{ID_PREFIX}index-".freeze
  COLLECTION_ID = 'usgs-htmc'
  COLLECTION_URL = 'https://www.usgs.gov/programs/national-geospatial-program/historical-topographic-maps-preserving-past'
  PROVIDER = 'U.S. Geological Survey'
  RIGHTS = 'USGS-authored or produced data and information are considered to be in the U.S. Public Domain.'
  PUBLIC_DOMAIN_MARK = 'https://creativecommons.org/publicdomain/mark/1.0/'

  # Index maps are generated here rather than by USGS, so they carry this repository's own license
  INDEX_MAP_RIGHTS = 'This index map is dedicated to the public domain under CC0 1.0. The maps it outlines are in ' \
                     'the U.S. Public Domain.'
  CC0 = 'https://creativecommons.org/publicdomain/zero/1.0/'

  # USGS's own description of the collection, from The National Map's dataset list
  COLLECTION_DESCRIPTION = [
    'The USGS Historical Topographic Map Collection (HTMC) includes maps in GeoTIFF and Geospatial PDF/GeoPDF ' \
    'formats. The HTMC provides a comprehensive digital repository of all scales and editions of topographic maps ' \
    'published by the USGS since the inception of the topographic mapping program in 1884. These maps are also ' \
    'available via https://ngmdb.usgs.gov/topoview/viewer/ in other formats.'
  ].freeze

  # Federal publishers as the publishers column abbreviates them: the Library of Congress name heading
  # for the creator and publisher fields, and how the description refers to them
  PUBLISHERS = {
    'USGS' => ['Geological Survey (U.S.)', 'the U.S. Geological Survey'],
    'USACE' => ['United States. Army. Corps of Engineers', 'the U.S. Army Corps of Engineers'],
    'USFS' => ['United States. Forest Service', 'the U.S. Forest Service'],
    'AMS' => ['United States. Army Map Service', 'the Army Map Service'],
    'TVA' => ['Tennessee Valley Authority', 'the Tennessee Valley Authority'],
    'WarDept' => ['United States. War Department', 'the War Department'],
    'DOC' => ['United States. Department of Commerce', 'the Department of Commerce'],
    'MIL' => ['United States. Armed Forces', 'the U.S. military'],
    'USBR' => ['United States. Bureau of Reclamation', 'the Bureau of Reclamation'],
    'BIA' => ['United States. Bureau of Indian Affairs', 'the Bureau of Indian Affairs'],
    'EPA' => ['United States. Environmental Protection Agency', 'the Environmental Protection Agency'],
    'BLM' => ['United States. Bureau of Land Management', 'the Bureau of Land Management'],
    'NPS' => ['United States. National Park Service', 'the National Park Service']
  }.freeze

  LANGUAGES = { 'English' => 'eng', 'Spanish' => 'spa' }.freeze

  VARIATIONS = {
    'Woodland' => 'woodland tint', 'ShadedRelief' => 'shaded relief', 'Planimetric' => 'planimetric',
    'OrthophotoQuad' => 'orthophotoquad', 'OrthophotoMap' => 'orthophotomap'
  }.freeze

  # The production steps the inventory records a year for, in the order they happen
  PRODUCTION_YEARS = [
    ['survey_year', 'surveyed in'],
    ['aerial_photo_year', 'aerial photographs from'],
    ['field_check_year', 'field checked in'],
    ['photo_inspection_year', 'photo inspected in'],
    ['photo_revision_year', 'photo revised in'],
    ['edit_year', 'last revised in'],
    ['imprint_year', 'printed in']
  ].freeze

  # Map a single inventory row to OGM Aardvark
  # @param row [Hash] one row of historicaltopo.csv, keyed by column name
  # @return [Hash] mapped OGM Aardvark JSON
  def self.map(row)
    new(row).map
  end

  def self.record_id(scan_id)
    "#{ID_PREFIX}#{scan_id}"
  end

  # The map's outline as a sheet of an OpenIndexMaps index map: a GeoJSON feature
  def self.sheet(row)
    new(row).sheet
  end

  # e.g. usgs-htmc-index-ca-24000, the index map of the 1:24,000-scale maps covering California
  def self.index_map_id(state_code, scale)
    "#{INDEX_MAP_PREFIX}#{state_code.downcase}-#{scale}"
  end

  # Whether a row has the GeoTIFF a record needs. For some maps the inventory has "Unregistered" in place
  # of a GeoTIFF URL, and without a GeoTIFF there's nothing to preview.
  def self.geotiff?(row)
    link?(row['geotiff_url'])
  end

  # Whether a column holds a web address rather than a placeholder
  def self.link?(field)
    field.to_s.strip.start_with?('https://', 'http://')
  end

  # The collection-level record. Its extent, years and modification date summarize the whole inventory,
  # so it only changes when the maps do.
  def self.collection(west:, east:, north:, south:, first_year:, last_year:, modified:, inventory_url:)
    envelope = format_envelope(west, east, north, south)
    compact(
      'id' => COLLECTION_ID,
      'dct_title_s' => 'USGS Historical Topographic Map Collection',
      'dct_description_sm' => COLLECTION_DESCRIPTION,
      'dct_creator_sm' => [PUBLISHERS['USGS'].first],
      'dct_publisher_sm' => [PUBLISHERS['USGS'].first],
      'dct_temporal_sm' => ["#{first_year}-#{last_year}"],
      'gbl_indexYear_im' => (first_year..last_year).to_a,
      'gbl_dateRange_drsim' => ["[#{first_year} TO #{last_year}]"],
      'dct_spatial_sm' => ['United States'],
      'dct_language_sm' => ['eng'],
      'schema_provider_s' => PROVIDER,
      'gbl_resourceClass_sm' => ['Collections'],
      'gbl_resourceType_sm' => ['Topographic maps'],
      'locn_geometry' => envelope,
      'dcat_bbox' => envelope,
      'dct_rights_sm' => [RIGHTS],
      'dct_license_sm' => [PUBLIC_DOMAIN_MARK],
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => "#{modified}T00:00:00Z",
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => {
        'http://schema.org/url' => COLLECTION_URL,
        'http://schema.org/downloadUrl' => [
          { 'url' => inventory_url, 'label' => 'Inventory of every map (CSV, zipped)' }
        ]
      }.to_json
    )
  end

  # The record for one index map: the maps at one scale that cover one U.S. state or territory. Like the
  # collection record, it summarizes its maps, so it only changes when they do.
  # @param maps [Integer] how many maps the index map outlines
  # @param sheets [Integer] how many distinct outlines those maps have between them
  # @param url [String] where the index map's GeoJSON is published
  # @param bytes [Integer] the GeoJSON's size
  def self.index_map(state:, scale:, maps:, sheets:, west:, east:, north:, south:, first_year:, last_year:, modified:,
                     url:, bytes:)
    place = Places.name(state)
    envelope = format_envelope(west, east, north, south)
    years = [first_year, last_year].compact.uniq
    compact(
      'id' => index_map_id(state, scale),
      'dct_title_s' => "Index to USGS 1:#{scale}-scale Quadrangles of #{place}",
      'dct_description_sm' => [
        "Outlines of the USGS topographic maps at 1:#{grouped(scale)} scale that cover #{place}, from the Historical " \
        "Topographic Map Collection: #{counted(maps, 'map')} of #{counted(sheets, 'sheet')}" \
        "#{", dated #{years.join(' to ')}" if years.any?}.",
        "Each map is outlined separately, so a sheet's editions and printings overlap, with the latest on top. Each " \
        "outline gives the map's record ID and links to its GeoTIFF, thumbnail and ScienceBase page."
      ],
      'dct_temporal_sm' => years.any? ? [years.join('-')] : nil,
      'gbl_indexYear_im' => years.any? ? (years.first..years.last).to_a : nil,
      'gbl_dateRange_drsim' => years.any? ? ["[#{years.first} TO #{years.last}]"] : nil,
      'dct_spatial_sm' => [place],
      'dct_language_sm' => ['eng'],
      'schema_provider_s' => PROVIDER,
      'gbl_resourceClass_sm' => ['Maps'],
      'gbl_resourceType_sm' => ['Index maps', 'Topographic maps'],
      'dcat_keyword_sm' => ['Historical Topographic Maps'],
      'dct_format_s' => 'GeoJSON',
      'locn_geometry' => envelope,
      'dcat_bbox' => envelope,
      'pcdm_memberOf_sm' => [COLLECTION_ID],
      'dct_rights_sm' => [INDEX_MAP_RIGHTS],
      'dct_license_sm' => [CC0],
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => "#{modified}T00:00:00Z",
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => {
        'https://openindexmaps.org' => url,
        'http://schema.org/downloadUrl' => [{ 'url' => url, 'label' => "GeoJSON (#{size_label(bytes)})" }]
      }.to_json
    )
  end

  # Solr's ENVELOPE(west, east, north, south) syntax. west > east crosses the antimeridian.
  def self.format_envelope(west, east, north, south)
    "ENVELOPE(#{[west, east, north, south].map { |coordinate| format_coordinate(coordinate) }.join(', ')})"
  end

  # The inventory pads coordinates to eight decimals; drop the padding
  def self.format_coordinate(value)
    format('%.8f', Float(value)).sub(/0+\z/, '').sub(/\.\z/, '')
  end

  # A coordinate as a JSON number, without the inventory's padding
  def self.coordinate(value)
    text = format_coordinate(value)
    text.include?('.') ? Float(text) : Integer(text)
  end

  # GeoJSON for the inventory's WKT, which is always a POLYGON or MULTIPOLYGON; nil for anything else
  def self.geojson_geometry(wkt)
    type = { 'POLYGON' => 'Polygon', 'MULTIPOLYGON' => 'MultiPolygon' }[wkt.to_s[/\A\s*([A-Z]+)\s*\(/, 1]]
    return nil unless type

    # The parentheses nest just as GeoJSON's arrays do, so the WKT turns into them in place
    nested = wkt.sub(/\A\s*[A-Z]+\s*/, '').gsub(/(-?[\d.]+)\s+(-?[\d.]+)/) do
      "[#{coordinate(Regexp.last_match(1))},#{coordinate(Regexp.last_match(2))}]"
    end
    { 'type' => type, 'coordinates' => JSON.parse(nested.tr('()', '[]')) }
  rescue JSON::ParserError, ArgumentError
    nil
  end

  # 48000 -> "48,000"
  def self.grouped(number)
    number.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ',')
  end

  # e.g. "1 map", "2,879 sheets"
  def self.counted(number, noun)
    "#{grouped(number)} #{noun}#{'s' unless number == 1}"
  end

  # e.g. "8.0 MB", or "3 KB" for a small file
  def self.size_label(bytes)
    bytes >= 100_000 ? format('%.1f MB', bytes / 1_000_000.0) : "#{(bytes / 1000.0).ceil} KB"
  end

  # Drop fields with nothing to say, so records don't carry empty strings or arrays
  def self.compact(record)
    record.reject { |_key, field| field.nil? || (field.respond_to?(:empty?) && field.empty?) }
  end

  attr_reader :row

  def initialize(row)
    @row = row.to_h.transform_values { |field| field.to_s.strip }
  end

  # Perform the metadata mapping to OGM Aardvark. Keys follow the order of GeoBlacklight's own records
  # (see edu.stanford.purl), so that diffs between runs read in a familiar order.
  # @return [Hash]
  def map
    self.class.compact(
      'id' => self.class.record_id(value('scan_id')),
      'dct_title_s' => title,
      'dct_alternative_sm' => list(value('map_name')),
      'dct_description_sm' => list(edition_paragraph, details_paragraph),
      'dct_creator_sm' => publisher_headings,
      'dct_publisher_sm' => publisher_headings,
      'dct_issued_s' => value('date_on_map'),
      'dct_temporal_sm' => list(value('date_on_map')),
      'gbl_indexYear_im' => list(value('date_on_map')&.to_i),
      'gbl_dateRange_drsim' => list(date_range),
      'dct_spatial_sm' => spatial,
      'dct_language_sm' => languages,
      'schema_provider_s' => PROVIDER,
      'dct_identifier_sm' => identifiers,
      'gbl_georeferenced_b' => true,
      'gbl_resourceClass_sm' => ['Maps'],
      'gbl_resourceType_sm' => ['Topographic maps'],
      'dcat_keyword_sm' => list('Historical Topographic Maps', series),
      'dct_format_s' => 'GeoTIFF',
      'locn_geometry' => value('geom_wkt') || envelope,
      'dcat_bbox' => envelope,
      'dcat_centroid' => centroid,
      'pcdm_memberOf_sm' => [COLLECTION_ID],
      'dct_rights_sm' => [RIGHTS],
      'dct_license_sm' => [PUBLIC_DOMAIN_MARK],
      'dct_accessRights_s' => 'Public',
      'gbl_mdModified_dt' => value('metadata_date')&.then { |date| "#{date}T00:00:00Z" },
      'gbl_mdVersion_s' => 'Aardvark',
      'dct_references_s' => references.to_json
    )
  end

  # The map as a sheet of an OpenIndexMaps index map (https://openindexmaps.org/specification/1.0.0): its
  # outline, and properties that tell it apart from the other editions and printings stacked on the same
  # outline. The label is what viewers show on hover and above the sheet's details.
  # @return [Hash] a GeoJSON feature
  def sheet
    {
      'type' => 'Feature',
      'properties' => self.class.compact(
        'label' => [value('map_name'), value('date_on_map')].compact.join(' ') +
                   (later_printing ? " (printed #{later_printing})" : ''),
        'title' => value('map_name'),
        'datePub' => value('date_on_map'),
        'dateSurvey' => value('survey_year'),
        'dateReprnt' => later_printing,
        'scale' => "1:#{self.class.grouped(value('map_scale'))}",
        'publisher' => publisher_codes.map { |code| PUBLISHERS[code].last.delete_prefix('the ') }.uniq.join('; '),
        'available' => true,
        'recId' => self.class.record_id(value('scan_id')),
        'websiteUrl' => link('sciencebase_url'),
        'download' => link('geotiff_url'),
        'thumbUrl' => link('thumbnail_url')
      ),
      'geometry' => self.class.geojson_geometry(value('geom_wkt')) || bounding_polygon
    }
  end

  # The U.S. states and territories the map covers, whose index maps it belongs in: those in state_list,
  # plus the primary state, which state_list occasionally leaves out. Canada and Mexico get no index maps.
  def index_map_states
    (state_codes + list(Places.code(value('primary_state')))).select { |code| Places.us?(code) }.uniq
  end

  private

  # A column's value, or nil when it's empty or the inventory's "not applicable" placeholder
  def value(key)
    field = row[key]
    field.nil? || field.empty? || field == 'NA' ? nil : field
  end

  # A link column's value, or nil when it holds a placeholder instead of a URL
  def link(key)
    value(key) if self.class.link?(row[key])
  end

  def list(*values)
    values.compact
  end

  # USGS's own title for the map, as ScienceBase and The National Map show it, plus the printing year when
  # that differs from the edition year: many editions survive in several printings, which would otherwise
  # all share one title
  def title
    title = "USGS 1:#{value('map_scale')}-scale Quadrangle for #{value('map_name')}, " \
            "#{state_code} #{value('date_on_map')}"
    later_printing ? "#{title} (printed #{later_printing})" : title
  end

  # The year this copy was printed, when that's later than the edition it's a printing of
  def later_printing
    printed = value('imprint_year')
    printed unless printed == value('date_on_map')
  end

  # The primary state's code, which USGS uses in titles and file names
  def state_code
    Places.code(value('primary_state')) || state_codes.first
  end

  def state_codes
    value('state_list').to_s.split(',').map(&:strip).select { |code| Places.name(code) }
  end

  def edition_paragraph
    sentence = "Scan of the #{value('date_on_map')} edition of the #{value('map_name')}, #{value('primary_state')}, " \
               "topographic map at 1:#{self.class.grouped(value('map_scale'))} scale"
    sentence += " (#{series} series)" if series
    sentence += ", published by #{publisher_phrase}" if publisher_phrase
    [sentence + '.', production_sentence].compact.join(' ')
  end

  # e.g. "Surveyed in 1903; last revised in 1915; printed in 1918."
  def production_sentence
    steps = PRODUCTION_YEARS.filter_map { |key, phrase| "#{phrase} #{value(key)}" if value(key) }
    return nil if steps.empty?

    sentence = steps.join('; ')
    "#{sentence[0].upcase}#{sentence[1..]}."
  end

  def details_paragraph
    details = []
    details << "Release: #{releases.join(', ')}." if releases.any?
    details << "Variations: #{variations.join(', ')}." if variations.any?
    if value('page_width_inches') && value('page_height_inches')
      details << "Sheet size: #{value('page_width_inches')} x #{value('page_height_inches')} inches."
    end
    details << "Printed projection: #{as_printed('projection_printed')}; " \
               "horizontal datum: #{as_printed('hdatum_printed')}."
    details << 'From the USGS Historical Topographic Map Collection.'
    details.join(' ')
  end

  # Releases other than the default "Standard", e.g. "Provisional"
  def releases
    value('print_releases').to_s.split(',').map(&:strip).reject { |release| release.empty? || release == 'Standard' }
  end

  def variations
    value('variations').to_s.split(',').map(&:strip).reject { |variation| variation.empty? || variation == 'None' }
                       .map { |variation| VARIATIONS.fetch(variation, variation) }
  end

  def as_printed(key)
    value(key) == 'Unstated' ? 'not stated' : value(key) || 'not stated'
  end

  # e.g. "15 x 15 minute"
  def series
    value('grid_size')&.downcase
  end

  def publisher_codes
    value('publishers').to_s.split(',').map(&:strip).select { |code| PUBLISHERS.key?(code) }
  end

  def publisher_headings
    publisher_codes.map { |code| PUBLISHERS[code].first }.uniq
  end

  # e.g. "the U.S. Army Corps of Engineers and the Army Map Service"
  def publisher_phrase
    phrases = publisher_codes.map { |code| PUBLISHERS[code].last }.uniq
    return nil if phrases.empty?
    return phrases.join(' and ') if phrases.size <= 2

    "#{phrases[0..-2].join(', ')}, and #{phrases.last}"
  end

  # Every year the inventory records for the map, from its survey to this copy's printing
  def date_range
    years = (PRODUCTION_YEARS.map(&:first) + ['date_on_map']).filter_map { |key| value(key)&.to_i }
    return nil if years.empty?

    "[#{years.min} TO #{years.max}]"
  end

  # Counties can only be paired with a state when the map lies in a single one
  def spatial
    codes = state_codes
    states = codes.map { |code| Places.name(code) }
    states = list(value('primary_state')) if states.empty?
    counties = codes.size == 1 ? Places.counties(value('county_list'), codes.first) : []
    (counties + states).uniq
  end

  def languages
    value('languages').to_s.split(',').filter_map { |language| LANGUAGES[language.strip] }.uniq
  end

  # The ScienceBase item and the inventory's product UUID, which survives a rescan
  def identifiers
    list(link('sciencebase_url'), value('product_inventory_uuid')&.then { |uuid| "urn:uuid:#{uuid}" })
  end

  def envelope
    self.class.format_envelope(value('westbc'), value('eastbc'), value('northbc'), value('southbc'))
  end

  # The bounding box as a GeoJSON polygon, counterclockwise as GeoJSON prefers
  def bounding_polygon
    west, east, north, south = %w[westbc eastbc northbc southbc].map { |key| self.class.coordinate(value(key)) }
    ring = [[west, south], [east, south], [east, north], [west, north], [west, south]]
    { 'type' => 'Polygon', 'coordinates' => [ring] }
  end

  # "latitude,longitude" of the map's center
  def centroid
    west, east, north, south = %w[westbc eastbc northbc southbc].map { |key| Float(value(key)) }
    "#{self.class.format_coordinate((north + south) / 2)},#{self.class.format_coordinate((west + east) / 2)}"
  end

  def references
    downloads = [['product_url', "GeoPDF#{file_size}"], ['geotiff_url', 'GeoTIFF']].filter_map do |key, label|
      { 'url' => link(key), 'label' => label } if link(key)
    end
    self.class.compact(
      'https://github.com/cogeotiff/cog-spec' => link('geotiff_url'),
      'http://schema.org/downloadUrl' => downloads,
      'http://www.opengis.net/cat/csw/csdgm' => link('metadata_url'),
      'http://schema.org/url' => link('sciencebase_url'),
      'http://schema.org/thumbnailUrl' => link('thumbnail_url')
    )
  end

  # The GeoPDF's size, which the inventory records; it doesn't record the GeoTIFF's
  def file_size
    bytes = value('product_filesize')&.to_i
    bytes&.positive? ? format(' (%.1f MB)', bytes / 1_000_000.0) : ''
  end
end
