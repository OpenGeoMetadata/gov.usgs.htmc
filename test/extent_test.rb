require 'minitest/autorun'
require_relative '../extent'

class ExtentTest < Minitest::Test
  def extent(*boxes)
    Extent.new.tap { |extent| boxes.each { |box| extent.add(*box) } }
  end

  def test_boxes_that_do_not_wrap
    covered = extent([-112.25, -112.0, 36.25, 36.0], [-66.75, -66.5, 18.25, 18.0])

    assert_equal [-112.25, -66.5], covered.longitudes
    assert_equal 36.25, covered.north
    assert_equal 18.0, covered.south
  end

  # Palau, Guam, Hawaii and Maine: the narrowest span runs east from Palau across the Pacific
  def test_span_crosses_the_antimeridian_when_that_is_narrower
    covered = extent([134.25, 134.75, 7.75, 7.25], [144.5, 145.0, 13.75, 13.25], [-158.25, -157.5, 21.75, 21.25],
                     [-68.0, -67.75, 45.0, 44.75])

    assert_equal [134.25, -67.75], covered.longitudes
  end

  def test_overlapping_boxes_merge
    assert_equal [-10.0, 10.0], extent([-10.0, 5.0, 1.0, 0.0], [0.0, 10.0, 1.0, 0.0]).longitudes
  end
end
