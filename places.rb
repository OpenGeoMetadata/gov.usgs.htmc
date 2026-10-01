# Place names for the codes in the inventory's state_list column, and the county-level
# places the county_list column can be turned into.
module Places
  US_STATES = {
    'AL' => 'Alabama', 'AK' => 'Alaska', 'AZ' => 'Arizona', 'AR' => 'Arkansas', 'CA' => 'California',
    'CO' => 'Colorado', 'CT' => 'Connecticut', 'DE' => 'Delaware', 'DC' => 'District of Columbia',
    'FL' => 'Florida', 'GA' => 'Georgia', 'HI' => 'Hawaii', 'ID' => 'Idaho', 'IL' => 'Illinois',
    'IN' => 'Indiana', 'IA' => 'Iowa', 'KS' => 'Kansas', 'KY' => 'Kentucky', 'LA' => 'Louisiana',
    'ME' => 'Maine', 'MD' => 'Maryland', 'MA' => 'Massachusetts', 'MI' => 'Michigan', 'MN' => 'Minnesota',
    'MS' => 'Mississippi', 'MO' => 'Missouri', 'MT' => 'Montana', 'NE' => 'Nebraska', 'NV' => 'Nevada',
    'NH' => 'New Hampshire', 'NJ' => 'New Jersey', 'NM' => 'New Mexico', 'NY' => 'New York',
    'NC' => 'North Carolina', 'ND' => 'North Dakota', 'OH' => 'Ohio', 'OK' => 'Oklahoma', 'OR' => 'Oregon',
    'PA' => 'Pennsylvania', 'RI' => 'Rhode Island', 'SC' => 'South Carolina', 'SD' => 'South Dakota',
    'TN' => 'Tennessee', 'TX' => 'Texas', 'UT' => 'Utah', 'VT' => 'Vermont', 'VA' => 'Virginia',
    'WA' => 'Washington', 'WV' => 'West Virginia', 'WI' => 'Wisconsin', 'WY' => 'Wyoming'
  }.freeze

  # Territories and freely associated states, named as the inventory's primary_state column names them.
  # Their county-level units (municipios, districts, islands) carry no "County" suffix.
  US_TERRITORIES = {
    'AS' => 'American Samoa', 'FM' => 'Federated States of Micronesia', 'GU' => 'Guam',
    'MP' => 'Northern Mariana Islands', 'PR' => 'Puerto Rico', 'PW' => 'Republic of Palau',
    'VI' => 'Virgin Islands'
  }.freeze

  # Maps published before Oklahoma statehood are filed under Indian Territory
  HISTORICAL = { 'IT' => 'Indian Territory' }.freeze

  # Neighboring provinces and states that border-straddling maps also cover
  CANADA = {
    'AB' => 'Alberta', 'BC' => 'British Columbia', 'MB' => 'Manitoba', 'NB' => 'New Brunswick',
    'ON' => 'Ontario', 'QC' => 'Quebec', 'SK' => 'Saskatchewan'
  }.freeze

  MEXICO = {
    'BCN' => 'Baja California', 'CHH' => 'Chihuahua', 'COA' => 'Coahuila', 'NLE' => 'Nuevo León',
    'SON' => 'Sonora', 'TAM' => 'Tamaulipas'
  }.freeze

  NAMES = US_STATES.merge(US_TERRITORIES, HISTORICAL, CANADA, MEXICO).freeze
  CODES = NAMES.invert.freeze

  # Name for a state_list code, or nil for an unknown code or the inventory's "NA"
  def self.name(code)
    NAMES[code]
  end

  # Code for a primary_state name, as USGS uses it in the map's title and file name
  def self.code(name)
    CODES[name]
  end

  # Whether a code is a U.S. state, the District of Columbia, or a territory
  def self.us?(code)
    US_STATES.key?(code) || US_TERRITORIES.key?(code)
  end

  # County-level places for a map that lies within one U.S. state or territory, qualified by
  # that state so that e.g. the many Washington Counties stay distinct. The inventory gives
  # bare names, so the kind of unit is inferred from the state and the name's own suffix.
  def self.counties(county_list, state_code)
    state = US_STATES[state_code] || US_TERRITORIES[state_code]
    return [] unless state && state_code != 'DC'

    county_list.to_s.split(',').map(&:strip).reject { |county| county.empty? || county == 'NA' }.map do |county|
      "#{county_name(county, state_code)}, #{state}"
    end
  end

  def self.county_name(county, state_code)
    if county.end_with?(' (city)')
      # An independent city, which is a place in its own right
      county.delete_suffix(' (city)')
    elsif county.end_with?(' (CA)')
      "#{county.delete_suffix(' (CA)')} Census Area"
    elsif state_code == 'LA'
      "#{county} Parish"
    elsif state_code == 'AK' || US_TERRITORIES.key?(state_code)
      # Alaska's boroughs, municipalities and cities-and-boroughs aren't told apart in the inventory
      county
    else
      "#{county} County"
    end
  end
end
