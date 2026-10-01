require 'json'
require 'set'
require_relative 'extent'
require_relative 'mapper'

# One index map: the outlines of the maps at one scale that cover one U.S. state or territory, as
# OpenIndexMaps GeoJSON (https://openindexmaps.org/specification/1.0.0), and the record that points to it.
#
# Every map gets its own outline, as the specification recommends, so the editions and printings of a
# sheet are stacked on the same outline.
class IndexMap
  attr_reader :state, :scale

  # Adds a map to the index maps of the states and territories it covers, starting any it's the first map in
  # @param index_maps [Hash] index maps by id
  # @param row [Hash] the map's row of the inventory
  def self.add(index_maps, row)
    mapper = Mapper.new(row)
    scale = row['map_scale'].to_s.strip
    return if scale.empty?

    # Built once, however many index maps the map is in
    feature = JSON.generate(mapper.sheet)
    mapper.index_map_states.each do |state|
      (index_maps[Mapper.index_map_id(state, scale)] ||= new(state, scale)).add(row, feature)
    end
  end

  def initialize(state, scale)
    @state = state
    @scale = scale
    @features = []
    @sheets = Set.new
    @extent = Extent.new
    @years = []
    @modified = nil
  end

  def id
    Mapper.index_map_id(state, scale)
  end

  # How many distinct outlines the maps have between them
  def sheets
    @sheets.size
  end

  # @param row [Hash] the map's row of the inventory
  # @param feature [String] the map's sheet, as JSON
  def add(row, feature)
    box = %w[westbc eastbc northbc southbc].map { |column| Float(row[column]) }
    @features << [order(row, box), feature]
    @sheets << box
    @extent.add(*box)
    year = row['date_on_map'].to_i
    @years << year if year.positive?
    @modified = [@modified, row['metadata_date'].to_s.strip].compact.max
  end

  # The GeoJSON, one sheet to a line so that a change to one map changes one line
  def geojson
    lines = @features.sort_by(&:first).map(&:last)
    "{\"type\":\"FeatureCollection\",\"features\":[\n#{lines.join(",\n")}\n]}\n"
  end

  # @param url [String] where the GeoJSON is published
  # @param bytes [Integer] the GeoJSON's size
  def record(url, bytes)
    west, east = @extent.longitudes
    Mapper.index_map(state: state, scale: scale, maps: @features.size, sheets: sheets, west: west, east: east,
                     north: @extent.north, south: @extent.south, first_year: @years.min, last_year: @years.max,
                     modified: @modified, url: url, bytes: bytes)
  end

  private

  # Outlines from west to east, and the maps stacked on each one oldest first, so that viewers draw the
  # latest edition and printing on top
  def order(row, box)
    [box, row['date_on_map'].to_i, row['imprint_year'].to_i, row['scan_id'].to_i]
  end
end
