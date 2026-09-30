# gov.usgs

This repository contains [OpenGeoMetadata Aardvark](https://opengeometadata.org/ogm-aardvark/) records for the U.S. Geological Survey's [Historical Topographic Map Collection](https://www.usgs.gov/programs/national-geospatial-program/historical-topographic-maps-preserving-past) (HTMC): scans of all scales and editions of the topographic maps USGS published from 1884 to 2006, about 186,000 maps.

The records are generated from USGS's public inventory of the collection. This repository is not an official USGS product.

This metadata is provided under the [CC0 v1.0 License](LICENSE), which allows for free use and redistribution without restrictions. The maps themselves are in the U.S. public domain.

## File Structure

```
metadata-aardvark/
  htmc/
    usgs-htmc.json               the collection record
    314/
      usgs-htmc-314262.json      one record per map, named by its id
      ...
withdrawn.json                   maps that have left the inventory
```

Each map's id is `usgs-htmc-` followed by its USGS scan ID. Records are grouped in directories by the thousands of their scan ID (`usgs-htmc-314262` is in `314/`), which keeps every directory under GitHub's 1,000-entry listing limit. A record's path follows from its id, so there is no `layers.json`.

## Metadata

- **Version:** OGM Aardvark, with no custom fields.
- **Other formats:** each record links the map's original FGDC metadata, which USGS hosts; it isn't copied here.
- **Updates:** a GitHub Actions workflow rebuilds every record daily from USGS's nightly inventory. Files only change when USGS's metadata for a map does, so an unchanged inventory produces no commit.
- **Validation:** the tests in `test/` run before every harvest.

### Source

USGS publishes an inventory of every map in the collection nightly, at [historicaltopo.zip](https://prd-tnm.s3.amazonaws.com/StagedProducts/Maps/Metadata/historicaltopo.zip). The zip holds:

- `historicaltopo.csv`: one row per map, 43 columns. `historicaltopo_readme.txt` in the same zip defines them.
- `historicaltopo.txt`: a report giving the number of maps and the date.

### Mapping

| Aardvark field | Inventory columns | Notes |
|---|---|---|
| `id` | `scan_id` | `usgs-htmc-314262` |
| `dct_title_s` | `map_scale`, `map_name`, `primary_state`, `date_on_map`, `imprint_year` | USGS's own title, as ScienceBase and The National Map show it, plus `(printed 1918)` when the printing year differs from the edition year. Many editions survive in several printings. |
| `dct_alternative_sm` | `map_name` | The printed map name |
| `dct_description_sm` | `date_on_map`, `map_scale`, `grid_size`, `publishers`, the production years, `print_releases`, `variations`, sheet size, `projection_printed`, `hdatum_printed` | Written out as two paragraphs |
| `dct_creator_sm`, `dct_publisher_sm` | `publishers` | Library of Congress name headings, e.g. `Geological Survey (U.S.)`. `Unknown` is left out. |
| `dct_issued_s`, `dct_temporal_sm`, `gbl_indexYear_im` | `date_on_map` | |
| `gbl_dateRange_drsim` | all the year columns | From the survey to this copy's printing |
| `dct_spatial_sm` | `state_list`, `county_list`, `primary_state` | See [Places](#places) |
| `dct_language_sm` | `languages` | `eng`, `spa` |
| `dct_identifier_sm` | `sciencebase_url`, `product_inventory_uuid` | |
| `dcat_keyword_sm` | `grid_size` | e.g. `Historical Topographic Maps`, `7.5 x 7.5 minute` |
| `locn_geometry` | `geom_wkt` | |
| `dcat_bbox`, `dcat_centroid` | `westbc`, `eastbc`, `northbc`, `southbc` | |
| `dct_relation_sm` | `gnis_cell_id` | The other maps of the same quadrangle: its other editions, printings and scales |
| `pcdm_memberOf_sm` | | Always `usgs-htmc`, the collection record |
| `gbl_mdModified_dt` | `metadata_date` | |
| `dct_references_s` | `geotiff_url`, `product_url`, `metadata_url`, `sciencebase_url`, `thumbnail_url` | COG, GeoPDF and GeoTIFF downloads, FGDC metadata, ScienceBase landing page, thumbnail |

The remaining fields are the same for every map:
- `gbl_resourceClass_sm` is `Maps`.
- `gbl_resourceType_sm` is `Topographic maps`.
- `dct_format_s` is `GeoTIFF`.
- `dct_rights_sm` carries USGS's public-domain statement.
- `dct_license_sm` is the Creative Commons Public Domain Mark.

### Places

`dct_spatial_sm` lists every state, territory, province or Mexican state in `state_list`. For a map within a single U.S. state or territory, it also lists that map's counties, qualified by the state: `Coconino County, Arizona`. The inventory gives bare county names, so their type is inferred:
- **Louisiana:** parishes.
- **Alaska:** census areas (the inventory's `(CA)` suffix), or bare names for boroughs and municipalities.
- **Independent cities:** the `(city)` suffix, listed as the city itself.
- **Territories:** municipios and districts, without a suffix.

Maps covering several states get no counties, because the inventory doesn't say which state each county is in.

## Withdrawn Records

When a map leaves the inventory, its record is deleted and logged in `withdrawn.json`.

- **Superseded:** if the map's product (`product_inventory_uuid`) reappears under a new scan ID, USGS rescanned it. The entry's reason is `superseded`, with `is_replaced_by` naming the new record.
- **Upstream-removed:** otherwise, the reason is `upstream-removed`.
- **Republished:** entries are only removed when their map comes back.

The harvester stops without changing anything in two cases:
- The CSV's row count disagrees with the report, as a truncated download would cause.
- The inventory has shrunk by more than 2% since the last run. Set `FORCE=1` if the drop is real.

## Running the Harvester

The harvester needs Ruby 4.0 (the `csv` and `minitest` gems ship with it) and `unzip`.

```bash
ruby harvester.rb
```

The harvester downloads the inventory to `tmp/`, rebuilds every record, and prints what changed. It takes about a minute. These environment variables change how it runs:

- `SOURCE=path/to/historicaltopo.zip` uses a local copy of the inventory, or a directory holding its CSV and report, instead of downloading it.
- `DRY_RUN=1` reports what would change without writing anything.
- `FORCE=1` allows a run that would withdraw more than 2% of the maps.

To run the tests:

```bash
for test in test/*_test.rb; do ruby "$test"; done
```

## How to Contribute

For problems with the records, open an issue in this repository. Every record is regenerated from USGS's inventory daily, so edits to the files would be overwritten:
- **How fields are mapped:** change `mapper.rb` and `places.rb`.
- **The inventory's own data:** corrections have to be made by USGS.
