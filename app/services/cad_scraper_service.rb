require 'net/http'
require 'uri'
require 'csv'
require 'zip'

# Phase 2 — CAD Bulk Property Fetcher
#
# Downloads bulk property export files from county appraisal districts / assessor offices
# and returns commercial property records for use by MapsOfMeaningService.
#
# Covers all 16 states where Restoration GC operates:
#   TX, OK, KS, CO, NE, MO, AR, LA, MS, AL, GA, TN, NC, SC, IN, MI
#
# Note on county key collisions: when the same county name exists in multiple
# states (e.g. Hall TX vs Hall NE, Dewey OK vs others), use "<County> <ST>"
# as the registry key and ensure storm.counties uses the same qualified name.
#
# Adapter types:
#   :dcad           — Dallas CAD (ACCOUNT_INFO.CSV + COM_DETAIL.CSV joined on ACCOUNT)
#   :hcad           — Harris CAD (year-templated URLs, tab-delimited TXT)
#   :generic_csv    — Generic ZIP → CSV/TXT (TrueAutomation and similar TX CADs)
#   :direct_csv     — Single unzipped CSV download
#   :direct_zip     — ZIP with multiple flat files, pick largest CSV/TXT
#   :arcgis_hub     — ArcGIS Hub open data portal (resolves download URL from about page)
#   :unavailable    — No direct bulk download; logs instructions, returns []
#
# Usage:
#   records = CadScraperService.fetch_commercial_properties(county: 'Dallas', state: 'TX')
#   # => [{ address:, city:, county:, state_abbr:, state_code:, sq_ft:, owner_entity:, lat:, lon: }, ...]
#
class CadScraperService
  # ---------------------------------------------------------------------------
  # CAD Registry — one entry per county/parish
  # ---------------------------------------------------------------------------
  REGISTRY = {

    # =========================================================================
    # TEXAS (TX)
    # =========================================================================

    # Dallas County — DCAD
    # https://www.dallascad.org/dataproducts.aspx
    # Files: ACCOUNT_INFO.CSV (tab-delimited) + COM_DETAIL.CSV, both in bulk ZIP
    'Dallas' => {
      state:   'TX',
      adapter: :dcad,
      urls: {
        bulk: 'https://www.dallascad.org/dataproducts.aspx'
      },
      note: 'Free download. DCAD2025_CERTIFIED ZIP contains ACCOUNT_INFO.CSV + COM_DETAIL.CSV.'
    },

    # Harris County — HCAD (Houston)
    # https://hcad.org/pdata/pdata-property-downloads.html
    'Harris' => {
      state:   'TX',
      adapter: :hcad,
      urls: {
        building: 'https://downloads.hcad.org/data/CAMA/#{year}/building_other.zip',
        account:  'https://downloads.hcad.org/data/CAMA/#{year}/real_acct_owner.zip'
      },
      note: 'Free download. Year-based URL; #{year} replaced at runtime.'
    },

    # Tarrant County — TAD (Fort Worth)
    # https://www.tad.org/resources/data-downloads
    # File: PropertyData-FullSet(Certified)2025.zip — requires free registration
    'Tarrant' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.tad.org/download/real_acct.zip'
      },
      note: 'Free download; requires registration at tad.org first.'
    },

    # Travis County — TCAD (Austin)
    # https://traviscad.org/publicinformation
    # Files: various certified appraisal export ZIPs
    'Travis' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://traviscad.org/downloads/real_acct.zip'
      },
      note: 'Free download. Multiple supplement exports available; SUPP 0 is primary certified roll.'
    },

    # Collin County — CCAD
    'Collin' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.collincad.org/downloads/real_acct.zip'
      }
    },

    # Denton County
    'Denton' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.dentoncad.com/downloads/real_acct.zip'
      }
    },

    # Ellis County
    'Ellis' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.elliscad.com/downloads/real_acct.zip'
      }
    },

    # Kaufman County
    'Kaufman' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.kaufmancad.org/downloads/real_acct.zip'
      }
    },

    # Bexar County — BCAD (San Antonio)
    'Bexar' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://bexar.trueautomation.com/clientdb/downloads/real_acct.zip'
      }
    },

    # Hall County, TX — Panhandle (Memphis, TX)
    # Small county appraisal district; uses BIS Consulting / TrueAutomation portal.
    # Key uses state suffix to avoid collision with Hall County NE (Grand Island).
    'Hall TX' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://hallcad.com/downloads/real_acct.zip'
      },
      note: 'Hall CAD (Memphis, TX). TrueAutomation/BIS portal — verify URL at hallcad.com. If ZIP 404s, contact (806) 259-3511 for current download link.'
    },

    # Collingsworth County, TX — Panhandle (Wellington, TX)
    # Small CAD using TrueAutomation / BIS Consulting portal.
    'Collingsworth' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://collingsworthcad.com/downloads/real_acct.zip'
      },
      note: 'Collingsworth CAD (Wellington, TX). TrueAutomation/BIS portal — verify URL at collingsworthcad.com. Contact (806) 447-2830 if download fails.'
    },

    # =========================================================================
    # OKLAHOMA (OK)
    # =========================================================================

    # Oklahoma County (Oklahoma City)
    # No direct bulk download. Contact arbryhut@oklahomacounty.org / (405) 713-1241
    # DataScoutPro (https://www.datascoutpro.com/) offers paid bulk data.
    'Oklahoma County' => {
      state:   'OK',
      adapter: :unavailable,
      urls:    {},
      note: 'Contact arbryhut@oklahomacounty.org or (405) 713-1241 for bulk data. Paid option: DataScoutPro (datascoutpro.com).'
    },

    # Tulsa County
    # Commercial bulk data is purchased per Records Reproduction Policy.
    # DataScoutPro also offers paid bulk data.
    'Tulsa' => {
      state:   'OK',
      adapter: :unavailable,
      urls:    {},
      note: 'Purchase required per Records Reproduction Policy. Paid option: DataScoutPro (datascoutpro.com). Contact assessor.tulsacounty.org.'
    },

    # Roger Mills County, OK — western Oklahoma (Cheyenne, OK)
    # Very small county (~3,600 pop). Uses Oklahoma DataScoutPro system.
    # Key uses full name to avoid ambiguity.
    'Roger Mills' => {
      state:   'OK',
      adapter: :unavailable,
      urls:    {},
      note: 'Small rural CAD. Use DataScoutPro (datascoutpro.com/ok/roger-mills) for paid bulk export, or contact Roger Mills County Assessor: (580) 497-3385.'
    },

    # Dewey County, OK — western Oklahoma (Taloga, OK)
    # Very small county. Uses Oklahoma DataScoutPro system.
    # Key uses state suffix to avoid potential future ambiguity.
    'Dewey OK' => {
      state:   'OK',
      adapter: :unavailable,
      urls:    {},
      note: 'Small rural CAD. Use DataScoutPro (datascoutpro.com/ok/dewey) for paid bulk export, or contact Dewey County Assessor: (580) 328-5331.'
    },

    # =========================================================================
    # KANSAS (KS)
    # =========================================================================

    # Johnson County — AIMS portal
    # https://aims.jocogov.org/AIMSData/FreeData.aspx
    # Various CSV files for Real Estate and Personal Property — free download
    'Johnson' => {
      state:   'KS',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://aims.jocogov.org/AIMSData/FreeData.aspx'
      },
      note: 'Free CSV download from AIMS portal at aims.jocogov.org/AIMSData/FreeData.aspx. Select Real Estate data tables.'
    },

    # Sedgwick County (Wichita)
    # https://sedgwick-county-gis-sedgwickcounty.hub.arcgis.com/datasets
    'Sedgwick' => {
      state:   'KS',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://sedgwick-county-gis-sedgwickcounty.hub.arcgis.com/datasets'
      },
      note: 'Free download via ArcGIS Hub. Filter to parcel/property datasets.'
    },

    # Wyandotte County (Kansas City, KS)
    # https://hub.arcgis.com/datasets/unifiedgov::land-parcels/about
    'Wyandotte' => {
      state:   'KS',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://hub.arcgis.com/datasets/unifiedgov::land-parcels/about'
      },
      note: 'Free download (CSV, Shapefile, KML, GeoJSON) from ArcGIS Hub.'
    },

    # Shawnee County (Topeka)
    # https://data-sncoks-gis.opendata.arcgis.com/datasets/unifiedgov::land-parcels/about
    'Shawnee' => {
      state:   'KS',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://data-sncoks-gis.opendata.arcgis.com/datasets/unifiedgov::land-parcels/about'
      },
      note: 'Free download (CSV, Shapefile, KML, GeoJSON) from ArcGIS Hub.'
    },

    # Douglas County, KS (Lawrence)
    # https://gis.dgcoks.gov/portal/home/item.html?id=b3b5a4b3f3d44afe922b62979a0dfdf2
    'Douglas KS' => {
      state:   'KS',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://gis.dgcoks.gov/portal/home/item.html?id=b3b5a4b3f3d44afe922b62979a0dfdf2'
      },
      note: 'Shapefile only; free download from county GIS portal.'
    },

    # Barber County, KS (Medicine Lodge) — south-central Kansas
    # Very small rural county (~4,500 pop); no bulk download portal confirmed.
    'Barber' => {
      state:   'KS',
      adapter: :unavailable,
      urls:    {},
      note: 'No bulk download portal found. Contact Barber County Appraiser: barbercounty.info or (620) 886-3723 to request commercial property export.'
    },

    # =========================================================================
    # COLORADO (CO)
    # =========================================================================

    # El Paso County (Colorado Springs)
    # https://assessor.elpasoco.com/assessordata/
    # Direct ZIP: epc_parcel_data.zip → ACCOUNT_INFO.CSV, COM_DETAIL.CSV, etc.
    'El Paso' => {
      state:   'CO',
      adapter: :direct_zip,
      urls: {
        bulk: 'https://assessor.elpasoco.com/wp-content/uploads/data/epc_parcel_data.zip'
      },
      col_map: {
        address:      %w[SITUS_ADDRESS site_address address],
        city:         %w[SITUS_CITY site_city city],
        owner_entity: %w[OWNER_NAME owner_name],
        sq_ft:        %w[TOTAL_SQ_FT building_sqft gross_sqft],
        state_code:   %w[STATE_CD property_class_code use_code],
        lat:          %w[LAT latitude GIS_LAT],
        lon:          %w[LON longitude GIS_LONG]
      },
      note: 'Free direct ZIP download. Contains ACCOUNT_INFO.CSV and COM_DETAIL.CSV.'
    },

    # Denver County
    # https://opendata-geospatialdenver.hub.arcgis.com/
    # Real Property Sales and Transfers via ArcGIS Hub
    'Denver' => {
      state:   'CO',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://opendata-geospatialdenver.hub.arcgis.com/datasets/55040dd13cb647bcbc7c555a4cfd6844_60/explore'
      },
      note: 'Free download (CSV, Shapefile, KML, GeoJSON). Navigate to dataset and click download.'
    },

    # Arapahoe County
    # https://gis.arapahoegov.com/assessordataexport/
    # Select tables and format, agree to terms
    'Arapahoe' => {
      state:   'CO',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://gis.arapahoegov.com/assessordataexport/'
      },
      note: 'Free download after selecting tables and agreeing to terms at the export portal.'
    },

    # Douglas County, CO (Castle Rock / Denver south suburb)
    # https://www.douglas.co.us/assessor/data-downloads/
    # Direct text files: Property_Subdivision.txt, Property_Ownership.txt, etc.
    'Douglas CO' => {
      state:   'CO',
      adapter: :direct_zip,
      urls: {
        ownership:    'https://www.douglas.co.us/assessor/downloads/Property_Ownership.txt',
        location:     'https://www.douglas.co.us/assessor/downloads/Property_Location.txt',
        improvements: 'https://www.douglas.co.us/assessor/downloads/Property_Improvements.txt'
      },
      note: 'Free direct TXT file downloads from Douglas County assessor data-downloads page.'
    },

    # Adams County (Aurora / Denver north suburbs)
    # https://adamscountyco.gov/our-county/elected-officials/assessor/maps-data/
    # Admin_2026_1v2.zip, Appraisal_2026_1.zip, etc.
    'Adams' => {
      state:   'CO',
      adapter: :direct_zip,
      urls: {
        admin:     'https://adamscountyco.gov/wp-content/uploads/Admin_2026_1v2.zip',
        appraisal: 'https://adamscountyco.gov/wp-content/uploads/Appraisal_2026_1.zip'
      },
      note: 'Free direct ZIP download. Check assessor maps-data page for latest year filenames.'
    },

    # =========================================================================
    # NEBRASKA (NE)
    # =========================================================================

    # Douglas County, NE (Omaha)
    # https://data-dogis.opendata.arcgis.com/
    # Direct bulk download not available; contact GIS dept for bulk request.
    'Douglas NE' => {
      state:   'NE',
      adapter: :unavailable,
      urls:    {},
      note: 'Parcels on GIS portal (data-dogis.opendata.arcgis.com) but direct bulk download unavailable. Contact Douglas County GIS for bulk data request.'
    },

    # Sarpy County (Bellevue / Omaha south)
    # https://gis.sarpy.gov/datasets/tax-parcels/about
    # Tax_Parcels.csv — free ArcGIS Hub download
    'Sarpy' => {
      state:   'NE',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://gis.sarpy.gov/datasets/tax-parcels/about'
      },
      note: 'Free CSV download from county GIS portal (Tax_Parcels.csv).'
    },

    # Lancaster County, NE (Lincoln)
    # https://opendata.lincoln.ne.gov/
    'Lancaster' => {
      state:   'NE',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://opendata.lincoln.ne.gov/'
      },
      note: 'Free download from City of Lincoln / Lancaster County open data portal.'
    },

    # Hall County, NE (Grand Island)
    # https://opengis.grand-island.com/
    'Hall' => {
      state:   'NE',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://opengis.grand-island.com/'
      },
      note: 'Free download from Hall County / Grand Island GIS portal.'
    },

    # Thayer County, NE (Hebron) — south-central Nebraska
    # Small county; uses gWorks property portal (no bulk download).
    'Thayer' => {
      state:   'NE',
      adapter: :unavailable,
      urls:    {},
      note: 'gWorks property portal at thayerne.gworks.com — no bulk CSV download. Contact Thayer County Assessor (Hebron, NE): (402) 768-6417 for commercial property export.'
    },

    # Fillmore County, NE (Geneva) — south-central Nebraska
    # Small county; uses gWorks property portal (no bulk download).
    # Key uses state suffix to avoid potential conflict.
    'Fillmore NE' => {
      state:   'NE',
      adapter: :unavailable,
      urls:    {},
      note: 'gWorks property portal at fillmorene.gworks.com — no bulk CSV download. Contact Fillmore County Assessor (Geneva, NE): (402) 759-4931 for commercial property export.'
    },

    # Gage County, NE (Beatrice) — southeast Nebraska
    # Uses gWorks property portal; no confirmed bulk CSV download.
    'Gage' => {
      state:   'NE',
      adapter: :unavailable,
      urls:    {},
      note: 'gWorks property portal at gagene.gworks.com — no bulk CSV download. Contact Gage County Assessor (Beatrice, NE): (402) 223-1316 for commercial property export.'
    },

    # =========================================================================
    # MISSOURI (MO)
    # =========================================================================

    # St. Louis County
    # https://data-stlcogis.opendata.arcgis.com/
    'St. Louis County' => {
      state:   'MO',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://data-stlcogis.opendata.arcgis.com/'
      },
      note: 'Parcel data via ArcGIS Hub. Bulk download not readily available; may require individual layer exports.'
    },

    # Jackson County (Kansas City, MO)
    # Commercial bulk data available from third-party:
    # https://fightjacksoncountytaxes.com/ — tblCOM_LEG_2025_ALL.xlsx (free)
    'Jackson' => {
      state:   'MO',
      adapter: :direct_zip,
      urls: {
        commercial: 'https://fightjacksoncountytaxes.com/tblCOM_LEG_2025_ALL.xlsx'
      },
      note: 'Free XLSX from fightjacksoncountytaxes.com (third-party). Verify URL annually for updated file.'
    },

    # St. Charles County (St. Louis west suburb)
    # Custom request, may involve a fee
    'St. Charles' => {
      state:   'MO',
      adapter: :unavailable,
      urls:    {},
      note: 'Bulk data requires custom request. May involve a fee. Contact sccmo.org/151/Assessor.'
    },

    # Greene County (Springfield, MO)
    # https://gishub-gimsoh29.opendata.arcgis.com/datasets/parcels
    'Greene' => {
      state:   'MO',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://gishub-gimsoh29.opendata.arcgis.com/datasets/parcels'
      },
      note: 'Parcel data via GIS Hub. Check for CSV export option on the dataset page.'
    },

    # Platte County, MO — no bulk data source found
    'Platte' => {
      state:   'MO',
      adapter: :unavailable,
      urls:    {},
      note: 'No bulk data source found. Contact Platte County assessor: co.platte.mo.us/real-property.'
    },

    # =========================================================================
    # ARKANSAS (AR)
    # =========================================================================

    # Pulaski County, AR (Little Rock)
    # Dropbox ZIP with commercial CAMA export (pipe-delimited TXT files):
    #   Commercial_Components.txt, Commercial_LumpSums.txt,
    #   Commercial_Occupancies.txt, Commercial_Sections.txt
    'Pulaski' => {
      state:   'AR',
      adapter: :direct_zip,
      urls: {
        cama: 'https://www.dropbox.com/scl/fi/iogswewv3za77ocqcznj4/CamaExport.zip?rlkey=8yh1qcm4ckw8y3t5oe5mlxdu3&e=1&dl=1'
      },
      col_map: {
        address:      %w[StreetAddress situs_address address],
        city:         %w[City situs_city city],
        owner_entity: %w[OwnerName owner_name],
        sq_ft:        %w[TotalSqFt total_sq_ft building_sqft gross_sqft],
        state_code:   %w[PropertyClass use_code class_code],
        lat:          %w[Latitude latitude],
        lon:          %w[Longitude longitude]
      },
      note: 'Free Dropbox ZIP. Contains pipe-delimited CAMA export files. dl=1 forces direct download.'
    },

    # Benton County, AR (Bentonville / Rogers / NW Arkansas)
    # GIS downloads (Shapefile/Geodatabase) only; no direct CSV bulk download
    'Benton AR' => {
      state:   'AR',
      adapter: :unavailable,
      urls:    {},
      note: 'Shapefile/Geodatabase only at gis.bentoncountyar.gov/downloads/index.html. No CSV bulk download available.'
    },

    # Washington County, AR (Fayetteville)
    # GIS page protected by captcha
    'Washington AR' => {
      state:   'AR',
      adapter: :unavailable,
      urls:    {},
      note: 'GIS download page is captcha-protected. Contact washingtoncountyar.gov assessor directly for bulk data.'
    },

    # =========================================================================
    # LOUISIANA (LA) — parishes
    # =========================================================================

    # Orleans Parish (New Orleans)
    # Fee-based: $500/year PDF or $500 programming + $0.025/record for CSV
    'Orleans' => {
      state:   'LA',
      adapter: :unavailable,
      urls:    {},
      note: 'Fee-based bulk data: $500/yr PDF or $500 programming fee + $0.025/record CSV/XLSX. Contact nolaassessor.com.'
    },

    # East Baton Rouge Parish
    # Direct CSV from Open Data BR portal — free
    'East Baton Rouge' => {
      state:   'LA',
      adapter: :direct_csv,
      urls: {
        properties: 'https://data.brla.gov/api/views/re5c-hrw9/rows.csv?accessType=DOWNLOAD'
      },
      note: 'Free direct CSV download from Open Data BR portal (Property Information dataset).'
    },

    # Caddo Parish (Shreveport)
    # Paid professional search and interactive mapping
    'Caddo' => {
      state:   'LA',
      adapter: :unavailable,
      urls:    {},
      note: 'Paid service for professional search/mapping at caddoassessor.org. Free individual property search only.'
    },

    # Jefferson Parish (New Orleans metro)
    # Individual property search only; no bulk download found
    'Jefferson LA' => {
      state:   'LA',
      adapter: :unavailable,
      urls:    {},
      note: 'No bulk download found. Individual property search at jpassessor.net.'
    },

    # Lafayette Parish
    # https://lafayetteassessor.com/forms
    # Various ZIP files: 2025 Certified Tax Roll, Preliminary Tax Roll, abstracts, shape files
    'Lafayette' => {
      state:   'LA',
      adapter: :direct_zip,
      urls: {
        tax_roll: 'https://lafayetteassessor.com/forms'
      },
      note: 'Free ZIP downloads from lafayetteassessor.com/forms. Navigate forms page to find the 2025 Certified Tax Roll compressed data file.'
    },

    # =========================================================================
    # MISSISSIPPI (MS)
    # =========================================================================

    # DeSoto County, MS (Memphis suburb)
    # GIS layers available but large parcel downloads fail ("Too Many Records")
    # Contact: gis@desotocountyms.gov, (662) 469-8019
    'DeSoto' => {
      state:   'MS',
      adapter: :unavailable,
      urls:    {},
      note: 'Small datasets via GIS hub; large parcel bulk download fails. Contact gis@desotocountyms.gov or (662) 469-8019.'
    },

    # Hinds County, MS (Jackson)
    # Public records request required; $0.50/page
    'Hinds' => {
      state:   'MS',
      adapter: :unavailable,
      urls:    {},
      note: 'Requires Public Records Request form. Cost: $0.50/page. Contact hindscountyms.com/elected-offices/tax-assessor.'
    },

    # Harrison County, MS (Biloxi / Gulfport)
    # No clear bulk data download found
    'Harrison' => {
      state:   'MS',
      adapter: :unavailable,
      urls:    {},
      note: 'No bulk download found on harrisoncountyms.gov. Contact assessor directly.'
    },

    # Panola County, MS (Batesville) — north Mississippi
    # Mississippi statewide GIS data at data.ms.gov; county parcel bulk download not confirmed.
    'Panola' => {
      state:   'MS',
      adapter: :unavailable,
      urls:    {},
      note: 'Check Mississippi open data portal (data.ms.gov) for Panola County parcels. Contact Panola County Tax Assessor: panolams.org or (662) 563-6270.'
    },

    # =========================================================================
    # ALABAMA (AL)
    # =========================================================================

    # Jefferson County, AL (Birmingham)
    # https://data-jeffco-al.opendata.arcgis.com/
    # Parcel data (Shapefile, CSV, KML, GeoJSON) — free download
    'Jefferson AL' => {
      state:   'AL',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://data-jeffco-al.opendata.arcgis.com/'
      },
      note: 'Free parcel data (CSV, Shapefile, KML, GeoJSON) from Jefferson County Open Data Portal.'
    },

    # Mobile County, AL — individual property lookup only
    'Mobile' => {
      state:   'AL',
      adapter: :unavailable,
      urls:    {},
      note: 'Individual property lookup only at mobile.capturecama.com. No bulk download available.'
    },

    # Madison County, AL (Huntsville) — individual property lookup only
    'Madison AL' => {
      state:   'AL',
      adapter: :unavailable,
      urls:    {},
      note: 'Individual property lookup only at madisoncountyal.gov. No bulk download available.'
    },

    # Montgomery County, AL — individual property lookup only
    'Montgomery AL' => {
      state:   'AL',
      adapter: :unavailable,
      urls:    {},
      note: 'Individual property lookup only at montgomery.capturecama.com. No bulk download available.'
    },

    # Baldwin County, AL — individual property lookup only
    'Baldwin' => {
      state:   'AL',
      adapter: :unavailable,
      urls:    {},
      note: 'Individual property lookup only. Contact baldwincountyal.gov/government/revenue-commission.'
    },

    # =========================================================================
    # GEORGIA (GA)
    # =========================================================================

    # Fulton County, GA (Atlanta)
    # https://gisdata.fultoncountyga.gov/datasets/fulcogis::tax-parcels/about
    # Tax_Parcels.csv — free ArcGIS Hub download
    'Fulton' => {
      state:   'GA',
      adapter: :arcgis_hub,
      urls: {
        about: 'https://gisdata.fultoncountyga.gov/datasets/fulcogis::tax-parcels/about'
      },
      note: 'Free CSV download (Tax_Parcels.csv) from Fulton County Open Data Portal.'
    },

    # Gwinnett County, GA (Atlanta NE suburb)
    # https://www.gwinnettcounty.com/documents/d/gwinnett-county/tax_assessor_property_ownership_data-zip
    # tax_assessor_property_ownership_data.zip — free direct download
    'Gwinnett' => {
      state:   'GA',
      adapter: :direct_zip,
      urls: {
        ownership: 'https://www.gwinnettcounty.com/documents/d/gwinnett-county/tax_assessor_property_ownership_data-zip'
      },
      note: 'Free direct ZIP download from Gwinnett County website.'
    },

    # DeKalb County, GA (Atlanta east)
    # https://dcgis.dekalbcountyga.gov/ — Shapefile or DWG via interactive map
    'DeKalb' => {
      state:   'GA',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://dcgis.dekalbcountyga.gov/portal/apps/experiencebuilder/experience/?id=29cc14eca506405a9788d95b1ed06566'
      },
      note: 'Download via interactive map (Shapefile, DWG). Navigate to parcels layer and export.'
    },

    # Cobb County, GA (Atlanta NW suburb)
    # https://geo-cobbcountyga.hub.arcgis.com/ — via GIS FTP or CD purchase
    'Cobb' => {
      state:   'GA',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://geo-cobbcountyga.hub.arcgis.com/'
      },
      note: 'Free download from ArcGIS Hub. GIS FTP site also available; CD purchase option exists.'
    },

    # =========================================================================
    # TENNESSEE (TN)
    # =========================================================================

    # Davidson County, TN (Nashville)
    # https://data.nashville.gov/ — open data portal; no single comprehensive commercial file
    'Davidson' => {
      state:   'TN',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://data.nashville.gov/'
      },
      note: 'Open data portal. No single comprehensive commercial property bulk file; filter Property Standards datasets manually.'
    },

    # Shelby County, TN (Memphis) — bulk data not found
    'Shelby TN' => {
      state:   'TN',
      adapter: :unavailable,
      urls:    {},
      note: 'No bulk download found on shelbycountytn.gov. Contact Assessor of Property directly.'
    },

    # Knox County, TN (Knoxville) — bulk data not found
    'Knox' => {
      state:   'TN',
      adapter: :unavailable,
      urls:    {},
      note: 'No bulk download found on knoxcounty.org/property. Contact Property Assessor directly.'
    },

    # =========================================================================
    # NORTH CAROLINA (NC)
    # =========================================================================

    # Wake County, NC (Raleigh)
    # https://www.wake.gov/.../real-estate-property-data-files
    # Direct CSV files: Tax Parcel CAMA Data + Tax Parcel Ownership Data
    'Wake' => {
      state:   'NC',
      adapter: :direct_csv,
      urls: {
        cama: 'https://www.wake.gov/departments-government/tax-administration/data-files-statistics-and-reports/real-estate-property-data-files'
      },
      note: 'Direct CSV download from Wake County Tax Administration data files page.'
    },

    # Mecklenburg County, NC (Charlotte)
    # https://mecklenburgcounty.hosted-by-files.com/OpenMapping/Parcel%20Data%20Archive/
    # TaxData_YYYY.zip — direct download of yearly ZIP
    'Mecklenburg' => {
      state:   'NC',
      adapter: :direct_zip,
      urls: {
        tax_data: "https://mecklenburgcounty.hosted-by-files.com/OpenMapping/Parcel%20Data%20Archive/TaxData_#{Date.today.year}.zip"
      },
      note: 'Free direct yearly ZIP (TaxData_YYYY.zip). Check archive for latest file if current year is not yet posted.'
    },

    # Guilford County, NC (Greensboro)
    # FTP access requires NCSU UNITY ID
    'Guilford' => {
      state:   'NC',
      adapter: :unavailable,
      urls:    {},
      note: 'FTP access requires NCSU UNITY ID. Off-campus proxy at lib.ncsu.edu/gis. Contact county directly for non-NCSU bulk access.'
    },

    # Durham County, NC
    # https://dconc.gov/Tax-Administration/Real-Property/Real-Property-Database
    # 2025 Real Property Database (CSV) — direct download, updated twice yearly
    'Durham' => {
      state:   'NC',
      adapter: :direct_csv,
      urls: {
        real_property: 'https://dconc.gov/Tax-Administration/Real-Property/Real-Property-Database'
      },
      note: 'Direct CSV download (large file). Updated twice yearly. Save locally before opening.'
    },

    # Orange County, NC (Chapel Hill)
    # https://web.co.orange.nc.us/propertytaxdatadownloads/
    # YYYYPropertyTaxData — direct download of yearly data files
    'Orange NC' => {
      state:   'NC',
      adapter: :direct_zip,
      urls: {
        tax_data: "https://web.co.orange.nc.us/propertytaxdatadownloads/#{Date.today.year}PropertyTaxData"
      },
      note: 'Free direct yearly data download from Orange County property tax data portal.'
    },

    # =========================================================================
    # SOUTH CAROLINA (SC)
    # =========================================================================

    # Charleston County, SC — FOIA required for bulk data
    'Charleston SC' => {
      state:   'SC',
      adapter: :unavailable,
      urls:    {},
      note: 'Bulk data requires FOIA request. Contact Charleston County Assessor. GIS portal: charleston-county-gis-chascogis.hub.arcgis.com/pages/open-data.'
    },

    # Greenville County, SC — $500 Shapefile purchase
    'Greenville SC' => {
      state:   'SC',
      adapter: :unavailable,
      urls:    {},
      note: 'Countywide Shapefile purchase: $500 at gcgis.org/AccessDistribution.html. Individual search free at greenvillecounty.org/realproperty.'
    },

    # Beaufort County, SC — data request form required
    'Beaufort' => {
      state:   'SC',
      adapter: :unavailable,
      urls:    {},
      note: 'Requires data request form at gis-department-mapping-site-collage-bcscgis.hub.arcgis.com. Contact Beaufort County GIS.'
    },

    # York County, SC (Rock Hill / Charlotte south suburb)
    # https://opendata-yorkcosc.hub.arcgis.com/
    # Patriot YCGIS Ownership + DeedHistory — free ArcGIS Hub download
    'York SC' => {
      state:   'SC',
      adapter: :arcgis_hub,
      urls: {
        portal: 'https://opendata-yorkcosc.hub.arcgis.com/'
      },
      note: 'Free download from York County Open Data Hub (Patriot YCGIS Ownership + DeedHistory).'
    },

    # Berkeley County, SC (Charleston north suburb) — likely requires data request
    'Berkeley SC' => {
      state:   'SC',
      adapter: :unavailable,
      urls:    {},
      note: 'Bulk data likely requires data request. Contact Berkeley County GIS: gis.berkeleycountysc.gov.'
    },

    # =========================================================================
    # INDIANA (IN)
    # =========================================================================

    # La Porte County, IN — northwest Indiana (Michigan City / La Porte)
    # Indiana statewide parcel data available via IndianaMAP open data portal.
    'La Porte' => {
      state:   'IN',
      adapter: :unavailable,
      urls:    {},
      note: 'Indiana parcel data available via IndianaMAP (hub.indianamap.org) — search for La Porte County parcels. Also check laportecounty.org GIS portal for county-level bulk export.'
    },

    # =========================================================================
    # MICHIGAN (MI)
    # =========================================================================

    # St. Joseph County, MI — southwest Michigan (Centreville)
    # Michigan statewide parcel data via Michigan Geographic Information Office (MGIO).
    'St. Joseph' => {
      state:   'MI',
      adapter: :unavailable,
      urls:    {},
      note: 'Michigan parcel data available via MGIO (michigan.gov/egle/maps-data). Contact St. Joseph County Equalization office (Centreville, MI) for commercial property bulk export. GIS portal: stjosephcountymi.org.'
    }

  }.freeze

  # ---------------------------------------------------------------------------
  # Texas commercial property category codes
  # ---------------------------------------------------------------------------
  COMMERCIAL_CODES = %w[F1 F2 L1 L2 B1 B2 B3 B4 X1 X2 X3 X4 X5 X6].freeze

  # Non-TX states: accept property codes starting with C, F, B, I (Commercial,
  # Flex/Industrial, Business, Industrial) as a broad commercial filter.
  COMMERCIAL_CODE_PATTERN = /\A[CFBI0-9]/i.freeze

  # Temporary download directory
  TMP_DIR = Rails.root.join('tmp', 'cad_downloads').freeze

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------
  # Returns array of normalized property hashes:
  #   { address:, city:, county:, state_abbr:, state_code:, sq_ft:,
  #     owner_entity:, lat:, lon: }
  #
  def self.fetch_commercial_properties(county:, state: nil)
    config = REGISTRY[county]
    unless config
      log "No CAD registry entry for #{county} — skipping"
      return []
    end

    if state && config[:state] != state
      log "Warning: #{county} is registered under #{config[:state]}, not #{state}"
    end

    FileUtils.mkdir_p(TMP_DIR)

    records = case config[:adapter]
              when :dcad        then fetch_dcad(county, config)
              when :hcad        then fetch_hcad(county, config)
              when :direct_csv  then fetch_direct_csv(county, config)
              when :direct_zip  then fetch_direct_zip(county, config)
              when :arcgis_hub  then fetch_arcgis_hub(county, config)
              when :unavailable then log_unavailable(county, config)
              else                   fetch_generic_csv(county, config)
              end

    log "CadScraper: #{records.size} commercial records from #{county} (#{config[:state]})"
    records
  rescue StandardError => e
    log "CadScraper error for #{county}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    []
  end

  # ---------------------------------------------------------------------------
  # DCAD adapter (Dallas County, TX)
  # ACCOUNT_INFO.CSV + COM_DETAIL.CSV, tab-delimited, joined on ACCOUNT
  # ---------------------------------------------------------------------------
  def self.fetch_dcad(county, config)
    url = config[:urls][:bulk]
    download_and_extract(url, county, 'bulk')

    extract_dir_path = TMP_DIR.join("#{county.downcase}_bulk_extracted")

    account_file = Dir[extract_dir_path.join('ACCOUNT_INFO.CSV')].first ||
                   Dir[extract_dir_path.join('account_info.csv')].first
    detail_file  = Dir[extract_dir_path.join('COM_DETAIL.CSV')].first ||
                   Dir[extract_dir_path.join('com_detail.csv')].first

    unless account_file
      log "DCAD: ACCOUNT_INFO.CSV not found — falling back to generic CSV parse"
      return fetch_generic_csv(county, { urls: { bulk: url } })
    end

    sq_ft_by_account = {}
    if detail_file
      CSV.foreach(detail_file, headers: true, col_sep: "\t",
                               encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
        acct = row['ACCOUNT']&.strip
        sq_ft_by_account[acct] = (row['TOTAL_SQ_FT'] || '0').to_f if acct
      end
    end

    records = []
    CSV.foreach(account_file, headers: true, col_sep: "\t",
                               encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
      state_code = clean(row['STATE_CD'])
      next unless COMMERCIAL_CODES.include?(state_code)

      acct    = row['ACCOUNT']&.strip
      sq_ft   = sq_ft_by_account[acct] || 0
      address = clean([row['SITUS_NUM'], row['SITUS_STREET'], row['SITUS_STREET_SFX']]
                      .map(&:to_s).map(&:strip).reject(&:empty?).join(' '))

      records << {
        address:      address,
        city:         clean(row['SITUS_CITY']),
        county:       county,
        state_abbr:   'TX',
        state_code:   state_code,
        sq_ft:        sq_ft,
        owner_entity: clean(row['OWNER_NAME']),
        lat:          row['GIS_LAT']&.to_f,
        lon:          row['GIS_LONG']&.to_f
      }
    end

    records.uniq { |r| r[:address] }
  end

  # ---------------------------------------------------------------------------
  # HCAD adapter (Harris County, TX)
  # Year-templated URLs, tab-delimited TXT files inside ZIPs
  # ---------------------------------------------------------------------------
  def self.fetch_hcad(county, config)
    year    = Date.today.year.to_s
    records = []

    config[:urls].each do |type, url_template|
      url      = url_template.gsub('#{year}', year)
      csv_path = download_and_extract(url, county, type.to_s)
      next unless csv_path

      CSV.foreach(csv_path, headers: true, col_sep: "\t",
                             encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
        next unless COMMERCIAL_CODES.include?(row['state_class']&.strip ||
                                              row['property_type']&.strip)

        records << {
          address:      clean([row['site_addr_1'], row['site_addr_2']].compact.join(' ')),
          city:         clean(row['site_addr_3'] || 'Houston'),
          county:       'Harris',
          state_abbr:   'TX',
          state_code:   clean(row['state_class'] || row['property_type']),
          sq_ft:        (row['building_sqft'] || row['gross_area'] || '0').to_f,
          owner_entity: clean(row['owner_name']),
          lat:          row['latitude']&.to_f,
          lon:          row['longitude']&.to_f
        }
      end
    end

    records.uniq { |r| r[:address] }
  end

  # ---------------------------------------------------------------------------
  # Generic CSV adapter (TrueAutomation-hosted TX CADs + other pipe/tab/CSV)
  # ---------------------------------------------------------------------------
  def self.fetch_generic_csv(county, config)
    records = []

    config[:urls].each do |type, url|
      csv_path = download_and_extract(url, county, type.to_s)
      next unless csv_path

      CSV.foreach(csv_path, headers: true, col_sep: detect_delimiter(csv_path),
                             encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
        state_code = clean(row['state_cd'] || row['state_code'] || row['prop_type_cd'] ||
                           row['property_use_cd'] || row['cat_code'])
        next unless commercial?(state_code, config[:state])

        sq_ft = (row['bldg_sqft'] || row['impr_sqft'] || row['building_sqft'] ||
                 row['gross_sqft'] || '0').to_f

        records << {
          address:      build_address(row),
          city:         clean(row['situs_city'] || row['city'] || row['site_city']),
          county:       county,
          state_abbr:   config[:state],
          state_code:   state_code,
          sq_ft:        sq_ft,
          owner_entity: clean(row['owner_name'] || row['agent_name'] || row['dba_name']),
          lat:          (row['lat'] || row['latitude'])&.to_f,
          lon:          (row['lon'] || row['lng'] || row['longitude'])&.to_f
        }
      end
    end

    records.uniq { |r| r[:address] }
  end

  # ---------------------------------------------------------------------------
  # Direct CSV adapter — single unzipped CSV download
  # ---------------------------------------------------------------------------
  def self.fetch_direct_csv(county, config)
    records = []

    config[:urls].each do |type, url|
      dest = TMP_DIR.join("#{county.downcase}_#{type}_#{Date.today}.csv")

      unless File.exist?(dest) && File.mtime(dest) > Time.now - 12.hours
        log "Downloading direct CSV (#{type}) from #{url}"
        download_file(url, dest)
      end

      next unless File.exist?(dest) && File.size(dest) > 0

      col_map = config[:col_map] || {}

      CSV.foreach(dest, headers: true, col_sep: detect_delimiter(dest),
                        encoding: 'UTF-8:UTF-8', liberal_parsing: true) do |row|
        state_code = resolve_col(row, col_map[:state_code]) ||
                     clean(row['state_cd'] || row['use_code'] || row['property_class'])
        next unless commercial?(state_code, config[:state])

        records << build_record(row, county, config, state_code, col_map)
      end
    end

    records.uniq { |r| r[:address] }
  rescue StandardError => e
    log "direct_csv error for #{county}: #{e.message}"
    []
  end

  # ---------------------------------------------------------------------------
  # Direct ZIP adapter — downloads ZIP, extracts CSV/TXT, parses largest file
  # Supports col_map override for non-standard column names
  # ---------------------------------------------------------------------------
  def self.fetch_direct_zip(county, config)
    records = []

    config[:urls].each do |type, url|
      next if url.blank?

      # XLSX requires manual download (no in-memory XLSX parsing here)
      if url =~ /\.(xlsx|xls)\z/i
        log "#{county}/#{type}: XLSX detected at #{url} — manual download required. " \
            "Import with rake pipeline:import_properties after converting to CSV."
        next
      end

      csv_path = download_and_extract(url, county, type.to_s)
      next unless csv_path

      col_map = config[:col_map] || {}

      CSV.foreach(csv_path, headers: true, col_sep: detect_delimiter(csv_path),
                             encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
        state_code = resolve_col(row, col_map[:state_code]) ||
                     clean(row['state_cd'] || row['use_code'] || row['property_class'] ||
                           row['prop_type_cd'] || row['cat_code'])
        next unless commercial?(state_code, config[:state])

        records << build_record(row, county, config, state_code, col_map)
      end
    end

    records.uniq { |r| r[:address] }
  rescue StandardError => e
    log "direct_zip error for #{county}: #{e.message}"
    []
  end

  # ---------------------------------------------------------------------------
  # ArcGIS Hub adapter
  # Attempts to derive a direct CSV download URL from the "about" page URL.
  # Falls back to logging manual download instructions.
  #
  # ArcGIS Hub CSV download pattern (when resolvable):
  #   https://{org}.hub.arcgis.com/api/download/v1/items/{dataset-slug}/csv?redirect=true&layers=0
  # ---------------------------------------------------------------------------
  def self.fetch_arcgis_hub(county, config)
    about_url = config[:urls][:about] || config[:urls][:portal] || config[:urls].values.first
    log "#{county}: ArcGIS Hub — attempting to resolve download from #{about_url}"

    # Try to construct a direct CSV download URL from an ArcGIS Hub "about" URL
    # Pattern: https://{org}.hub.arcgis.com/datasets/{org}::{slug}/about
    if about_url =~ %r{hub\.arcgis\.com/datasets/([^/?]+)/about}
      dataset_slug = $1
      base         = about_url.split('/datasets/').first
      csv_url      = "#{base}/api/download/v1/items/#{dataset_slug}/csv?redirect=true&layers=0"
      log "#{county}: Trying derived ArcGIS Hub CSV URL: #{csv_url}"

      csv_path = TMP_DIR.join("#{county.downcase}_arcgis_#{Date.today}.csv")
      unless File.exist?(csv_path) && File.mtime(csv_path) > Time.now - 12.hours
        download_file(csv_url, csv_path)
      end

      if File.exist?(csv_path) && File.size(csv_path) > 1024
        return parse_arcgis_csv(csv_path, county, config)
      end
    end

    # Fallback: log manual download instructions
    log "#{county}: ArcGIS Hub auto-download not resolved. " \
        "Manual step: navigate to #{about_url}, click Download → CSV, " \
        "then import with rake pipeline:import_properties[storm_id,/path/to/file.csv]."
    []
  end

  def self.parse_arcgis_csv(csv_path, county, config)
    records = []
    col_map = config[:col_map] || {}

    CSV.foreach(csv_path, headers: true, encoding: 'UTF-8:UTF-8', liberal_parsing: true) do |row|
      state_code = resolve_col(row, col_map[:state_code]) ||
                   clean(row['USE_CODE'] || row['use_code'] || row['PROPERTY_CLASS'] ||
                         row['PropertyClass'] || row['LandUseCode'] || row['LAND_USE'])
      next unless commercial?(state_code, config[:state])

      records << build_record(row, county, config, state_code, col_map)
    end

    records.uniq { |r| r[:address] }
  rescue StandardError => e
    log "ArcGIS CSV parse error for #{county}: #{e.message}"
    []
  end

  # ---------------------------------------------------------------------------
  # Unavailable adapter — logs sourcing instructions, returns []
  # ---------------------------------------------------------------------------
  def self.log_unavailable(county, config)
    note = config[:note] || 'No bulk data source documented.'
    log "#{county} (#{config[:state]}): UNAVAILABLE — #{note}"
    []
  end

  # ---------------------------------------------------------------------------
  # Download + extract ZIP → path to largest CSV/TXT file in extract dir
  # ---------------------------------------------------------------------------
  def self.download_and_extract(url, county, label)
    zip_path = TMP_DIR.join("#{county.downcase}_#{label}_#{Date.today}.zip")

    unless File.exist?(zip_path) && File.mtime(zip_path) > Time.now - 12.hours
      log "Downloading #{label} data from #{url}"
      download_file(url, zip_path)
    end

    return nil unless File.exist?(zip_path) && File.size(zip_path) > 0

    extract_dir = TMP_DIR.join("#{county.downcase}_#{label}_extracted")
    FileUtils.mkdir_p(extract_dir)

    Zip::File.open(zip_path) do |zip|
      zip.each do |entry|
        next unless entry.name =~ /\.(csv|txt|dat)\z/i
        dest = extract_dir.join(File.basename(entry.name))
        entry.extract(dest) { true }  # overwrite
      end
    end

    Dir[extract_dir.join('*')].select { |f| f =~ /\.(csv|txt|dat)\z/i }
                               .max_by { |f| File.size(f) }
  rescue Zip::Error => e
    log "ZIP extraction failed for #{county}/#{label}: #{e.message}"
    nil
  end

  # ---------------------------------------------------------------------------
  # HTTP download with redirect following
  # ---------------------------------------------------------------------------
  def self.download_file(url, dest_path)
    uri       = URI.parse(url)
    redirects = 0

    loop do
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                      read_timeout: 180, open_timeout: 30) do |http|
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Mozilla/5.0 (RestorationGC-Clawbot/1.0)'

        http.request(request) do |response|
          case response
          when Net::HTTPSuccess
            File.open(dest_path, 'wb') { |f| response.read_body { |chunk| f.write(chunk) } }
            return dest_path
          when Net::HTTPRedirection
            raise 'Too many redirects' if (redirects += 1) > 8
            uri = URI.parse(response['location'])
          else
            log "HTTP #{response.code} fetching #{url}"
            return nil
          end
        end
      end
    end
  rescue StandardError => e
    log "Download error for #{url}: #{e.message}"
    nil
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build normalized record from a CSV row, with optional col_map overrides
  def self.build_record(row, county, config, state_code, col_map = {})
    {
      address:      resolve_col(row, col_map[:address]) || build_address(row),
      city:         resolve_col(row, col_map[:city]) ||
                    clean(row['situs_city'] || row['SITUS_CITY'] || row['city'] || row['City'] ||
                          row['site_city']  || row['CITY']),
      county:       county,
      state_abbr:   config[:state],
      state_code:   state_code,
      sq_ft:        (resolve_col(row, col_map[:sq_ft]) ||
                     row['bldg_sqft'] || row['TOTAL_SQ_FT'] || row['building_sqft'] ||
                     row['gross_sqft'] || row['TotalSqFt'] || '0').to_f,
      owner_entity: resolve_col(row, col_map[:owner_entity]) ||
                    clean(row['owner_name'] || row['OWNER_NAME'] || row['OwnerName'] ||
                          row['agent_name'] || row['dba_name']),
      lat:          (resolve_col(row, col_map[:lat]) ||
                     row['lat'] || row['LAT'] || row['latitude'] || row['GIS_LAT'])&.to_f,
      lon:          (resolve_col(row, col_map[:lon]) ||
                     row['lon'] || row['LON'] || row['longitude'] || row['GIS_LONG'] ||
                     row['lng'])&.to_f
    }
  end

  def self.build_address(row)
    num    = row['situs_num']    || row['SITUS_NUM']    || row['site_addr_num']  || row['house_num'] || ''
    street = row['situs_street'] || row['SITUS_STREET'] || row['site_addr_str']  ||
             row['street_name']  || row['StreetName']   || ''
    sfx    = row['situs_street_sfx'] || row['SITUS_STREET_SFX'] || row['street_sfx'] || ''
    clean([num, street, sfx].map(&:to_s).map(&:strip).reject(&:empty?).join(' '))
  end

  # Resolve a row value using an ordered list of candidate column names
  def self.resolve_col(row, candidates)
    return nil unless candidates.is_a?(Array)
    candidates.each do |col|
      val = clean(row[col])
      return val if val.present?
    end
    nil
  end

  # Returns true if the state_code indicates a commercial property.
  # TX uses specific DPS codes; other states get a broad pattern match.
  def self.commercial?(state_code, state_abbr)
    return false if state_code.blank?
    return COMMERCIAL_CODES.include?(state_code) if state_abbr == 'TX'
    state_code.match?(COMMERCIAL_CODE_PATTERN)
  end

  def self.detect_delimiter(path)
    first_line = File.open(path, 'r:ISO-8859-1') { |f| f.readline rescue '' }
    pipes  = first_line.count('|')
    tabs   = first_line.count("\t")
    commas = first_line.count(',')

    if pipes > commas && pipes > tabs then '|'
    elsif tabs > commas               then "\t"
    else                                   ','
    end
  rescue
    ','
  end

  def self.clean(val)
    val.to_s.strip.presence
  end

  def self.log(msg)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Rails.logger.info "[#{timestamp}] CadScraper: #{msg}"
    puts "[#{timestamp}] CadScraper: #{msg}"
  end
end
