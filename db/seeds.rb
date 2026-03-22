# Business Leader Network — seed data
#
# Mirrors the Kantwert / Neo4j use case:
#   - B2B sales and marketing network of senior business leaders
#   - Graph captures professional connections, company affiliations,
#     board memberships, and career history
#   - Run:  rake db:seed
#
require_relative '../lib/neo4j/client'
require_relative '../config/initializers/neo4j'

# ── Wipe existing data ────────────────────────────────────────────────────────
puts "Clearing existing graph data…"
NEO4J.query("MATCH (n) DETACH DELETE n")

# ── Companies ─────────────────────────────────────────────────────────────────
puts "Creating companies…"

companies = {}
[
  { id: "c-finvest",   name: "FinVest Capital",      industry: "FinTech",        size: "200-500",   hq_city: "Frankfurt",  website: "https://finvest.example.com",   description: "Digital investment platform for institutional clients." },
  { id: "c-bluerock",  name: "BlueRock Analytics",   industry: "Data & AI",      size: "500-1000",  hq_city: "Berlin",     website: "https://bluerock.example.com",  description: "Enterprise AI and predictive analytics." },
  { id: "c-nordsec",   name: "NordSec GmbH",         industry: "Cybersecurity",  size: "100-200",   hq_city: "Hamburg",    website: "https://nordsec.example.com",   description: "B2B cybersecurity solutions for finance and healthcare." },
  { id: "c-terrahealth",name:"TerraHealth AG",        industry: "HealthTech",     size: "1000-5000", hq_city: "Munich",     website: "https://terrahealth.example.com",description: "Digital health records and telemedicine infrastructure." },
  { id: "c-urbanprop", name: "UrbanProp Group",       industry: "Real Estate",    size: "50-100",    hq_city: "Cologne",    website: "https://urbanprop.example.com",  description: "Commercial real-estate investment and development." },
  { id: "c-logiq",     name: "LogiQ Systems",         industry: "SaaS / ERP",     size: "200-500",   hq_city: "Stuttgart",  website: "https://logiq.example.com",     description: "Supply chain and ERP software for mid-market manufacturers." },
  { id: "c-greenshift", name: "GreenShift Ventures", industry: "CleanTech",      size: "50-100",    hq_city: "Leipzig",    website: "https://greenshift.example.com", description: "VC and advisory for renewable-energy start-ups." },
  { id: "c-alphamedia", name: "AlphaMedia Group",     industry: "Media & Comms",  size: "500-1000",  hq_city: "Munich",     website: "https://alphamedia.example.com", description: "B2B content, events, and marketing intelligence." },
].each do |attrs|
  NEO4J.query(<<~CYPHER, attrs.transform_keys(&:to_s))
    MERGE (c:Company {id: $id})
    SET c.name        = $name,
        c.industry    = $industry,
        c.size        = $size,
        c.hq_city     = $hq_city,
        c.website     = $website,
        c.description = $description
  CYPHER
  companies[attrs[:id]] = attrs
end

# ── Business Leaders ──────────────────────────────────────────────────────────
puts "Creating business leaders…"

leaders = {}
[
  { id: "l-001", name: "Sophie Reinhardt",  title: "CEO",              email: "s.reinhardt@finvest.example.com",   linkedin_url: "https://linkedin.com/in/sophiereinhardt",  bio: "20 years in investment banking; founded FinVest after leading Deutsche Bank's digital unit.", influence_score: 95, company: "c-finvest"   },
  { id: "l-002", name: "Marcus Heller",     title: "CTO",              email: "m.heller@bluerock.example.com",     linkedin_url: "https://linkedin.com/in/marcusheller",     bio: "AI researcher turned entrepreneur; ex-SAP Labs, PhD in machine learning.",                  influence_score: 87, company: "c-bluerock"  },
  { id: "l-003", name: "Julia Schwarz",     title: "COO",              email: "j.schwarz@nordsec.example.com",     linkedin_url: "https://linkedin.com/in/juliaschwarz",     bio: "Scaled NordSec from 10 to 180 employees; board member at two FinTech start-ups.",          influence_score: 78, company: "c-nordsec"   },
  { id: "l-004", name: "Tobias Keller",     title: "Managing Director",email: "t.keller@terrahealth.example.com",  linkedin_url: "https://linkedin.com/in/tobiaskeller",     bio: "Healthcare IT veteran; former CMO at Siemens Healthineers.",                               influence_score: 82, company: "c-terrahealth"},
  { id: "l-005", name: "Lena Brandt",       title: "CFO",              email: "l.brandt@urbanprop.example.com",    linkedin_url: "https://linkedin.com/in/lenabrandt",       bio: "Structured finance specialist; ex-Goldman Sachs real-estate division.",                      influence_score: 74, company: "c-urbanprop" },
  { id: "l-006", name: "Felix Wagner",      title: "CEO",              email: "f.wagner@logiq.example.com",        linkedin_url: "https://linkedin.com/in/felixwagner",      bio: "Serial SaaS founder; previously exited two ERP ventures.",                                  influence_score: 80, company: "c-logiq"     },
  { id: "l-007", name: "Anna Bauer",        title: "Partner",          email: "a.bauer@greenshift.example.com",    linkedin_url: "https://linkedin.com/in/annabauer",        bio: "CleanTech investor with 15 portfolio companies across wind, solar, and storage.",            influence_score: 88, company: "c-greenshift"},
  { id: "l-008", name: "Daniel Koch",       title: "Chief Strategy Officer", email: "d.koch@alphamedia.example.com",linkedin_url: "https://linkedin.com/in/danielkoch",      bio: "Media strategist; advisory roles at three DAX-40 communications boards.",                   influence_score: 70, company: "c-alphamedia"},
  { id: "l-009", name: "Nina Vogel",        title: "VP Sales",         email: "n.vogel@bluerock.example.com",      linkedin_url: "https://linkedin.com/in/ninavogel",        bio: "Enterprise sales leader; runs BlueRock's DACH revenue team.",                               influence_score: 62, company: "c-bluerock"  },
  { id: "l-010", name: "Christoph Müller",  title: "Head of Products", email: "c.mueller@finvest.example.com",     linkedin_url: "https://linkedin.com/in/christophmueller",  bio: "Product-led growth specialist; ex-N26 and Wefox.",                                          influence_score: 65, company: "c-finvest"   },
  { id: "l-011", name: "Sarah Fischer",     title: "CIO",              email: "s.fischer@terrahealth.example.com", linkedin_url: "https://linkedin.com/in/sarahfischer",     bio: "Cloud and data architecture expert; led TerraHealth's migration to Azure.",                  influence_score: 71, company: "c-terrahealth"},
  { id: "l-012", name: "Patrick Neumann",   title: "COO",              email: "p.neumann@logiq.example.com",       linkedin_url: "https://linkedin.com/in/patrickneumann",   bio: "Operations expert; previously ran EMEA operations for Oracle.",                              influence_score: 68, company: "c-logiq"     },
  { id: "l-013", name: "Eva Hoffmann",      title: "CEO",              email: "e.hoffmann@urbanprop.example.com",  linkedin_url: "https://linkedin.com/in/evahoffmann",      bio: "Real-estate development leader; responsible for 2B EUR in assets under management.",         influence_score: 76, company: "c-urbanprop" },
  { id: "l-014", name: "Klaus Berger",      title: "CISO",             email: "k.berger@nordsec.example.com",      linkedin_url: "https://linkedin.com/in/klausberger",      bio: "Cybersecurity architect; 18 years protecting financial-sector infrastructure.",              influence_score: 72, company: "c-nordsec"   },
  { id: "l-015", name: "Mia Schreiber",     title: "Head of Marketing",email: "m.schreiber@alphamedia.example.com",linkedin_url: "https://linkedin.com/in/miaschreiber",     bio: "B2B brand strategist; keynote speaker at dmexco and Marketing Week.",                       influence_score: 60, company: "c-alphamedia"},
  { id: "l-016", name: "Oliver Ziegler",    title: "Angel Investor",   email: "o.ziegler@independent.example.com", linkedin_url: "https://linkedin.com/in/oliverziegler",    bio: "Ex-CTO turned angel; 25+ portfolio companies in SaaS and FinTech.",                         influence_score: 91, company: nil           },
  { id: "l-017", name: "Hannah Braun",      title: "VP Engineering",   email: "h.braun@nordsec.example.com",       linkedin_url: "https://linkedin.com/in/hannahbraun",      bio: "Security engineering leader; PhD in cryptography from TU Berlin.",                          influence_score: 66, company: "c-nordsec"   },
  { id: "l-018", name: "Lukas Hartmann",    title: "CPO",              email: "l.hartmann@bluerock.example.com",   linkedin_url: "https://linkedin.com/in/lukashartmann",    bio: "Product leader focused on ML-driven decision intelligence.",                                influence_score: 69, company: "c-bluerock"  },
  { id: "l-019", name: "Sabine Werner",     title: "CFO",              email: "s.werner@greenshift.example.com",   linkedin_url: "https://linkedin.com/in/sabinewerner",     bio: "Green finance expert; structured the first German green bond for a start-up.",              influence_score: 73, company: "c-greenshift"},
  { id: "l-020", name: "Thomas Schäfer",    title: "Managing Partner", email: "t.schaefer@greenshift.example.com", linkedin_url: "https://linkedin.com/in/thomasschaefer",   bio: "20-year renewable-energy investor; advisory board at IRENA.",                               influence_score: 85, company: "c-greenshift"},
].each do |attrs|
  company_id = attrs.delete(:company)
  NEO4J.query(<<~CYPHER, attrs.transform_keys(&:to_s))
    MERGE (l:BusinessLeader {id: $id})
    SET l.name            = $name,
        l.title           = $title,
        l.email           = $email,
        l.linkedin_url    = $linkedin_url,
        l.bio             = $bio,
        l.influence_score = toInteger($influence_score)
  CYPHER

  if company_id
    NEO4J.query(<<~CYPHER, leader_id: attrs[:id], company_id: company_id)
      MATCH (l:BusinessLeader {id: $leader_id}), (c:Company {id: $company_id})
      MERGE (l)-[:WORKS_AT {current: true, since: '2019'}]->(c)
    CYPHER
  end

  leaders[attrs[:id]] = attrs
end

# ── Professional Connections (KNOWS) ─────────────────────────────────────────
puts "Creating connections…"

connections = [
  # Sophie (CEO FinVest) is a central hub
  ["l-001", "l-002", "2018", "conference",    9],
  ["l-001", "l-005", "2015", "board",         8],
  ["l-001", "l-007", "2020", "investment",    9],
  ["l-001", "l-016", "2017", "mentorship",   10],
  ["l-001", "l-010", "2019", "colleague",     7],
  ["l-001", "l-008", "2021", "event",         6],

  # Marcus (CTO BlueRock) tech cluster
  ["l-002", "l-009", "2019", "colleague",     8],
  ["l-002", "l-018", "2018", "colleague",     9],
  ["l-002", "l-011", "2017", "conference",    7],
  ["l-002", "l-016", "2016", "alumni",        8],
  ["l-002", "l-006", "2020", "conference",    6],

  # Julia (COO NordSec) operations cluster
  ["l-003", "l-014", "2016", "colleague",     9],
  ["l-003", "l-017", "2018", "colleague",     8],
  ["l-003", "l-004", "2019", "conference",    6],
  ["l-003", "l-012", "2020", "peer_group",    7],

  # Tobias (MD TerraHealth)
  ["l-004", "l-011", "2015", "colleague",    10],
  ["l-004", "l-007", "2021", "investment",    7],
  ["l-004", "l-016", "2018", "board",         8],

  # Felix (CEO LogiQ)
  ["l-006", "l-012", "2014", "colleague",     9],
  ["l-006", "l-016", "2019", "investor",      9],
  ["l-006", "l-008", "2021", "event",         5],

  # Anna (Partner GreenShift) — key bridge to CleanTech
  ["l-007", "l-019", "2017", "colleague",     9],
  ["l-007", "l-020", "2015", "colleague",    10],
  ["l-007", "l-013", "2020", "conference",    6],
  ["l-007", "l-005", "2019", "board",         7],

  # Oliver Ziegler (Angel) — super-connector
  ["l-016", "l-013", "2016", "investment",    8],
  ["l-016", "l-015", "2018", "advisory",      7],
  ["l-016", "l-019", "2020", "conference",    6],
  ["l-016", "l-020", "2017", "investment",    9],

  # Daniel / Media cluster
  ["l-008", "l-015", "2019", "colleague",     8],
  ["l-008", "l-013", "2021", "event",         5],

  # Cross-cluster bridges (important for network analysis)
  ["l-009", "l-010", "2020", "conference",    6],
  ["l-010", "l-018", "2021", "peer_group",    7],
  ["l-011", "l-017", "2019", "conference",    5],
  ["l-014", "l-016", "2017", "advisory",      7],
  ["l-005", "l-013", "2010", "colleague",     8],
  ["l-019", "l-020", "2013", "colleague",    10],
  ["l-012", "l-006", "2015", "colleague",     9],
  ["l-015", "l-009", "2022", "event",         4],
]

connections.each do |a_id, b_id, since, source, strength|
  NEO4J.query(<<~CYPHER, a: a_id, b: b_id, since: since, source: source, strength: strength)
    MATCH (a:BusinessLeader {id: $a}), (b:BusinessLeader {id: $b})
    MERGE (a)-[:KNOWS {since: $since, source: $source, strength: $strength}]->(b)
  CYPHER
end

# ── Board Memberships ─────────────────────────────────────────────────────────
puts "Creating board memberships…"

[
  ["l-001", "c-bluerock",   "2020"],
  ["l-007", "c-terrahealth","2019"],
  ["l-016", "c-logiq",      "2021"],
  ["l-016", "c-finvest",    "2018"],
  ["l-004", "c-nordsec",    "2020"],
  ["l-008", "c-greenshift", "2022"],
  ["l-005", "c-urbanprop",  "2015"],
].each do |leader_id, company_id, since|
  NEO4J.query(<<~CYPHER, leader_id: leader_id, company_id: company_id, since: since)
    MATCH (l:BusinessLeader {id: $leader_id}), (c:Company {id: $company_id})
    MERGE (l)-[:BOARD_MEMBER_OF {since: $since}]->(c)
  CYPHER
end

# ── Work History ──────────────────────────────────────────────────────────────
puts "Creating work history…"

[
  ["l-001", "c-alphamedia", "2010", "2014", "Head of Finance"],
  ["l-002", "c-logiq",      "2013", "2017", "Lead Engineer"],
  ["l-005", "c-finvest",    "2012", "2016", "Senior Analyst"],
  ["l-006", "c-bluerock",   "2011", "2014", "Co-Founder"],
  ["l-009", "c-finvest",    "2016", "2019", "Sales Manager"],
  ["l-010", "c-nordsec",    "2015", "2019", "Product Manager"],
  ["l-016", "c-bluerock",   "2008", "2012", "CTO"],
].each do |leader_id, company_id, from, to, title|
  NEO4J.query(<<~CYPHER, l: leader_id, c: company_id, from: from, to: to, title: title)
    MATCH (l:BusinessLeader {id: $l}), (c:Company {id: $c})
    MERGE (l)-[:PREVIOUSLY_WORKED_AT {from: $from, to: $to, title: $title}]->(c)
  CYPHER
end

puts "Seed complete. Graph contains:"
puts "  Leaders:     #{NEO4J.query('MATCH (l:BusinessLeader) RETURN count(l) AS n').first['n']}"
puts "  Companies:   #{NEO4J.query('MATCH (c:Company) RETURN count(c) AS n').first['n']}"
puts "  Connections: #{NEO4J.query('MATCH ()-[r:KNOWS]->() RETURN count(r) AS n').first['n']}"
puts "  Board seats: #{NEO4J.query('MATCH ()-[r:BOARD_MEMBER_OF]->() RETURN count(r) AS n').first['n']}"
