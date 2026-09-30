require 'csv'

# USGS's nightly inventory of the Historical Topographic Map Collection. historicaltopo.zip holds
# historicaltopo.csv, one row per map, and historicaltopo.txt, a summary report giving the number of
# maps and the date. A directory holding the two files can stand in for the zip.
class Inventory
  CSV_NAME = 'historicaltopo.csv'
  SUMMARY_NAME = 'historicaltopo.txt'

  class Error < StandardError; end

  attr_reader :path

  def initialize(path)
    raise Error, "No inventory at #{path}" unless File.exist?(path)

    @path = path
  end

  # Yields each map's row as a Hash keyed by column name. Rows are streamed out of the zip rather than
  # read into memory: the CSV is about 185 MB.
  def each_row
    read(CSV_NAME) do |io|
      CSV.new(io, headers: true).each { |row| yield row.to_h }
    end
  end

  # The number of maps the summary report says the CSV lists, if there is a report
  def total
    summary[/^Total Files\s*\|\s*(\d+)/, 1]&.to_i
  end

  # The date USGS generated the inventory, if there is a report
  def date
    summary[/^Last Updated\s*\|\s*(\S+)/, 1]
  end

  private

  def summary
    @summary ||= exists?(SUMMARY_NAME) ? read(SUMMARY_NAME, &:read) : ''
  end

  def zip?
    File.file?(path)
  end

  def exists?(name)
    return File.exist?(File.join(path, name)) unless zip?

    IO.popen(['unzip', '-l', path, name], err: File::NULL, &:read)
    $?.success?
  end

  # Opens one of the two files, reading straight out of the zip when there is one
  def read(name, &block)
    return File.open(File.join(path, name), 'r:bom|utf-8', &block) unless zip?

    result = IO.popen(['unzip', '-p', path, name], 'r:bom|utf-8', err: File::NULL, &block)
    raise Error, "Could not read #{name} from #{path} (unzip exited with #{$?.exitstatus})" unless $?.success?

    result
  end
end
