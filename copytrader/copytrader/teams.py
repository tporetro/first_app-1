"""Pro-team tables: 'City|Nickname[|extra Kalshi labels...]'.

Kalshi labels are city-style ("Los Angeles D", "Atlanta"); Polymarket uses
nicknames or "City Nickname". Candidate Kalshi labels are auto-generated
(city, city+initial, city+nickname) plus any extras listed here. Run
`python run.py --check-sports` to see which live Kalshi labels are NOT covered.
"""
NFL = """Arizona|Cardinals;Atlanta|Falcons;Baltimore|Ravens;Buffalo|Bills;Carolina|Panthers;Chicago|Bears;Cincinnati|Bengals;Cleveland|Browns;Dallas|Cowboys;Denver|Broncos;Detroit|Lions;Green Bay|Packers;Houston|Texans;Indianapolis|Colts;Jacksonville|Jaguars;Kansas City|Chiefs;Las Vegas|Raiders;Los Angeles|Chargers|Los Angeles C;Los Angeles|Rams|Los Angeles R;Miami|Dolphins;Minnesota|Vikings;New England|Patriots;New Orleans|Saints;New York|Giants|New York G;New York|Jets|New York J;Philadelphia|Eagles;Pittsburgh|Steelers;San Francisco|49ers;Seattle|Seahawks;Tampa Bay|Buccaneers;Tennessee|Titans;Washington|Commanders"""
NBA = """Atlanta|Hawks;Boston|Celtics;Brooklyn|Nets;Charlotte|Hornets;Chicago|Bulls;Cleveland|Cavaliers;Dallas|Mavericks;Denver|Nuggets;Detroit|Pistons;Golden State|Warriors;Houston|Rockets;Indiana|Pacers;Los Angeles|Clippers|Los Angeles C;Los Angeles|Lakers|Los Angeles L;Memphis|Grizzlies;Miami|Heat;Milwaukee|Bucks;Minnesota|Timberwolves;New Orleans|Pelicans;New York|Knicks|New York;Oklahoma City|Thunder;Orlando|Magic;Philadelphia|76ers;Phoenix|Suns;Portland|Trail Blazers|Portland;Sacramento|Kings;San Antonio|Spurs;Toronto|Raptors;Utah|Jazz;Washington|Wizards"""
MLB = """Arizona|Diamondbacks;Atlanta|Braves;Baltimore|Orioles;Boston|Red Sox;Chicago|Cubs|Chicago C;Chicago|White Sox|Chicago WS;Cincinnati|Reds;Cleveland|Guardians;Colorado|Rockies;Detroit|Tigers;Houston|Astros;Kansas City|Royals;Los Angeles|Angels|Los Angeles A;Los Angeles|Dodgers|Los Angeles D;Miami|Marlins;Milwaukee|Brewers;Minnesota|Twins;New York|Mets|New York M;New York|Yankees|New York Y;Athletics|Athletics|Athletics,Sacramento,Oakland;Philadelphia|Phillies;Pittsburgh|Pirates;San Diego|Padres;San Francisco|Giants;Seattle|Mariners;St. Louis|Cardinals;Tampa Bay|Rays;Texas|Rangers;Toronto|Blue Jays;Washington|Nationals"""
NHL = """Anaheim|Ducks;Boston|Bruins;Buffalo|Sabres;Calgary|Flames;Carolina|Hurricanes;Chicago|Blackhawks;Colorado|Avalanche;Columbus|Blue Jackets;Dallas|Stars;Detroit|Red Wings;Edmonton|Oilers;Florida|Panthers;Los Angeles|Kings;Minnesota|Wild;Montreal|Canadiens;Nashville|Predators;New Jersey|Devils;New York|Islanders|New York I;New York|Rangers|New York R;Ottawa|Senators;Philadelphia|Flyers;Pittsburgh|Penguins;San Jose|Sharks;Seattle|Kraken;St. Louis|Blues;Tampa Bay|Lightning;Toronto|Maple Leafs;Utah|Mammoth,Hockey Club;Vancouver|Canucks;Vegas|Golden Knights;Washington|Capitals;Winnipeg|Jets"""

import re


def norm(s: str) -> str:
    s = s.lower().replace("&", " and ").replace("'", "")
    s = re.sub(r"[^a-z0-9 ]+", " ", s)
    toks = s.split()
    if toks and toks[-1] == "st":          # "Missouri St." -> "missouri state"
        toks[-1] = "state"
    return " ".join(toks)


def _parse(table: str):
    teams = []
    for row in table.split(";"):
        parts = row.strip().split("|")
        city, nick = parts[0], parts[1]
        extra = [norm(x) for x in (parts[2].split(",") if len(parts) > 2 else [])]
        labels = {norm(city), norm(f"{city} {nick}"), norm(f"{city} {nick[0]}")} | set(extra)
        teams.append({"city": city, "nick": nick, "labels": labels,
                      "names": {norm(nick), norm(f"{city} {nick}")}})
    return teams


PRO = {"nfl": _parse(NFL), "nba": _parse(NBA), "mlb": _parse(MLB), "nhl": _parse(NHL)}


def pro_team(league: str, name: str):
    """Polymarket name -> team dict (or None)."""
    n = norm(name)
    for t in PRO.get(league, []):
        if n in t["names"]:
            return t
    return None


def label_team(league: str, label: str):
    """Kalshi label -> list of candidate teams (usually one)."""
    n = norm(label)
    return [t for t in PRO.get(league, []) if n in t["labels"]]
