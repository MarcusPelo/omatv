import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "marcuspelo.omatv"
  ipcTarget: "marcuspelo.omatv"

  readonly property string language: {
    var v = settings ? settings.language : undefined
    if (typeof v === "string" && v.length > 0) return v
    if (root.envLanguage) return root.envLanguage
    return "en-US"
  }

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property string barIcon: "" // nf-fa-film

  // ---------------------------------------------------------------- credentials
  property string apiKey: ""
  property string envLanguage: ""
  property bool apiKeyLoaded: false
  // TMDB accepts either a 32-char v3 API key (query parameter only) or a v4
  // read access token (a JWT, sent as a bearer header). Header auth is
  // preferable because the secret never enters the URL at all, so prefer it
  // whenever the configured value looks like a JWT.
  readonly property bool useBearer: root.apiKey.indexOf("eyJ") === 0

  // ---------------------------------------------------------------- account
  // A TMDB v3 session_id never expires, so the browser approval is a one-time
  // step: once exchanged, the id lives in ~/.config/omatv/session.json (0600)
  // and is reused across shell restarts.
  property string sessionId: ""
  property int accountId: 0
  property string accountName: ""
  property bool sessionLoaded: false
  property string requestToken: ""
  // idle | requesting | awaiting | exchanging | connected | error
  property string authState: "idle"
  property string authError: ""

  readonly property bool connected: root.sessionId !== "" && root.accountId > 0

  // ---------------------------------------------------------------- navigation
  // navStack holds the screens behind the current one, so Escape walks back
  // through them one at a time and only closes the panel at the root.
  property var navStack: []
  property string view: "search"
  property int detailId: 0

  // ---------------------------------------------------------------- search
  property string queryText: ""
  property var results: []
  // The query the on-screen results actually belong to. Kept so a stale list is
  // never shown next to a newer query, and so a slow response from an earlier
  // keystroke cannot overwrite a newer one.
  property string resultsQuery: ""
  property string inFlightQuery: ""
  property string typeFilter: "all"
  property bool searchLoading: false
  property bool searchDone: false
  property string searchError: ""

  // ---------------------------------------------------------------- movie
  property var movie: null
  property bool movieLoading: false
  property string movieError: ""
  property var movieCache: ({})

  // ---------------------------------------------------------------- tv
  property var tv: null
  property bool tvLoading: false
  property string tvError: ""
  property var tvCache: ({})

  // ---------------------------------------------------------------- person
  property var person: null
  property bool personLoading: false
  property string personError: ""
  property var personCache: ({})
  property bool bioExpanded: false

  readonly property var filteredResults: {
    if (root.typeFilter === "all") return root.results
    return root.results.filter(function(r) { return r.media_type === root.typeFilter })
  }

  // ---------------------------------------------------------------- formatting
  function imgUrl(path, size) {
    if (!path) return ""
    return "https://image.tmdb.org/t/p/" + size + path
  }

  function thousands(n) {
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }

  function money(v) {
    var n = Number(v) || 0
    if (n <= 0) return "—"
    return "$" + root.thousands(n)
  }

  function runtimeText(mins) {
    var m = Number(mins) || 0
    if (m <= 0) return ""
    var h = Math.floor(m / 60)
    var rem = m % 60
    return h > 0 ? (h + "h " + rem + "m") : (rem + "m")
  }

  function yearOf(dateStr) {
    var s = String(dateStr || "")
    return s.length >= 4 ? s.substring(0, 4) : ""
  }

  function scoreText(vote) {
    var v = Number(vote) || 0
    if (v <= 0) return ""
    return Math.round(v * 10) + "%"
  }

  function scoreColor(vote) {
    var v = Number(vote) || 0
    if (v >= 7) return "#8fd694"
    if (v >= 5) return "#e0af68"
    if (v > 0) return "#e06c75"
    return root.dim
  }

  readonly property var languageNames: ({
    "en": "English", "pt": "Portuguese", "es": "Spanish", "fr": "French",
    "de": "German", "it": "Italian", "ja": "Japanese", "ko": "Korean",
    "zh": "Chinese", "ru": "Russian", "hi": "Hindi", "ar": "Arabic",
    "sv": "Swedish", "da": "Danish", "no": "Norwegian", "fi": "Finnish",
    "nl": "Dutch", "pl": "Polish", "tr": "Turkish", "he": "Hebrew",
    "th": "Thai", "cs": "Czech", "hu": "Hungarian", "el": "Greek"
  })

  function languageName(code) {
    var c = String(code || "").toLowerCase()
    if (!c) return "—"
    return root.languageNames[c] || c.toUpperCase()
  }

  function mediaIcon(type) {
    if (type === "tv") return ""     // nf-fa-television
    if (type === "movie") return ""  // nf-fa-film
    if (type === "person") return "" // nf-fa-user
    return ""
  }

  function resultTitle(r) {
    return r.title || r.name || "Unknown"
  }

  function resultDate(r) {
    return r.release_date || r.first_air_date || ""
  }

  function resultPoster(r) {
    return r.poster_path || r.profile_path || ""
  }

  function resultMeta(r) {
    if (r.media_type === "person") {
      var known = r.known_for_department || ""
      var titles = (r.known_for || []).map(function(k) { return k.title || k.name }).filter(function(t) { return !!t })
      return [known, titles.slice(0, 2).join(", ")].filter(function(p) { return !!p }).join(" · ")
    }
    var year = root.yearOf(root.resultDate(r))
    var score = root.scoreText(r.vote_average)
    return [year, score].filter(function(p) { return !!p }).join(" · ")
  }

  // ---------------------------------------------------------------- networking
  // The secret is written to curl's stdin as a config file (`-K -`) rather than
  // passed on the command line, so it never appears in argv and cannot be read
  // out of `ps` or process inspection. With a v4 token it also stays out of the
  // URL entirely; a v3 key has to ride in the query string because TMDB offers
  // no header form for it, but stdin still keeps it out of the process table.
  //
  // Callers are responsible for checking apiKeyLoaded/apiKey and the process's
  // own `running` state first, so that a request arriving too early is parked
  // as pending rather than silently dropped.
  // curl's config-file quoting only requires backslash and double-quote to be
  // escaped. The bodies built here are JSON.stringify of plain strings/numbers/
  // booleans, so nothing else (tabs, embedded $VARs) can occur in practice.
  function curlConfigEscape(s) {
    return String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  }

  function startRequest(proc, path, extraQuery, method, body) {
    var url = "https://api.themoviedb.org/3" + path
    var query = "language=" + encodeURIComponent(root.language)
    if (extraQuery) query += "&" + extraQuery
    if (!root.useBearer) query += "&api_key=" + encodeURIComponent(root.apiKey)
    url += (path.indexOf("?") >= 0 ? "&" : "?") + query

    var config = 'url = "' + url + '"\n'
    if (root.useBearer) config += 'header = "Authorization: Bearer ' + root.apiKey + '"\n'
    config += 'header = "Accept: application/json"\n'
    if (method && method !== "GET") config += 'request = "' + method + '"\n'
    if (body !== undefined) {
      // Favorite/watchlist need a JSON body, not just query params. It goes in
      // the same stdin config as everything else, so it is never in argv.
      config += 'header = "Content-Type: application/json"\n'
      config += 'data = "' + root.curlConfigEscape(JSON.stringify(body)) + '"\n'
    }

    proc.reqConfig = config
    // -f is deliberately omitted: the auth endpoints answer with a 401/4xx and
    // a JSON body explaining why, and that message is worth showing the user.
    proc.command = ["curl", "-sS", "--max-time", "10", "-K", "-"]
    proc.stdinEnabled = true
    proc.running = true
  }

  // Requests can be asked for before ~/.config/omatv/.env has been read, or
  // while an earlier request on the same process is still in flight. Both are
  // parked here and replayed instead of being dropped, which would otherwise
  // leave a screen blank with no error and no retry.
  property bool searchPending: false
  property int pendingMovieId: 0
  property int pendingTvId: 0
  property int pendingPersonId: 0
  // The id each in-flight detail request was issued for. A response whose id no
  // longer matches what the user is looking at is discarded, so a slow earlier
  // request cannot overwrite the screen with the previous title.
  property int inFlightMovieId: 0
  property int inFlightTvId: 0
  property int inFlightPersonId: 0

  function flushPending() {
    if (!root.apiKeyLoaded || !root.apiKey) return
    if (root.searchPending && !searchProc.running) {
      root.searchPending = false
      root.runSearch()
    }
    if (root.pendingMovieId && !movieProc.running) {
      var mid = root.pendingMovieId
      root.pendingMovieId = 0
      root.fetchMovie(mid)
    }
    if (root.pendingTvId && !tvProc.running) {
      var tid = root.pendingTvId
      root.pendingTvId = 0
      root.fetchTv(tid)
    }
    if (root.pendingPersonId && !personProc.running) {
      var pid = root.pendingPersonId
      root.pendingPersonId = 0
      root.fetchPerson(pid)
    }
  }

  onApiKeyLoadedChanged: root.flushPending()

  // TMDB signals failure with a JSON envelope rather than an empty body, so
  // every handler runs its parsed payload past this before trusting it — a 404
  // or a rejected key would otherwise be cached as if it were real data.
  function tmdbError(data) {
    if (!data) return "Empty response from TMDB"
    // `success === false` is TMDB's one consistent error signal, verified
    // live against several endpoints. status_message alone is NOT reliable:
    // the favorite/watchlist write endpoints answer a real success with
    // {"status_code":1,"status_message":"Success."} and no `success` field at
    // all, so treating any status_message as an error misclassified every
    // successful toggle as a failure.
    if (data.success === false) return String(data.status_message || "TMDB request failed")
    return ""
  }

  function parseEnv(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line || line.indexOf("#") === 0) continue
      var eq = line.indexOf("=")
      if (eq < 0) continue
      var key = line.substring(0, eq).trim()
      var value = line.substring(eq + 1).trim().replace(/^["']|["']$/g, "")
      if (key === "API_KEY" || key === "TMDB_API_KEY") root.apiKey = value
      else if (key === "LANGUAGE") root.envLanguage = value
    }
    root.apiKeyLoaded = true
  }

  // ---------------------------------------------------------------- search
  function runSearch() {
    var q = root.queryText.trim()
    if (!q) {
      root.results = []
      root.resultsQuery = ""
      root.searchDone = false
      root.searchError = ""
      return
    }
    root.searchLoading = true
    root.searchError = ""
    if (!root.apiKeyLoaded || searchProc.running) {
      root.searchPending = true
      return
    }
    if (!root.apiKey) {
      root.searchLoading = false
      root.searchError = "API key not configured in ~/.config/omatv/.env"
      return
    }
    root.searchPending = false
    root.inFlightQuery = q
    root.startRequest(searchProc, "/search/multi",
      "query=" + encodeURIComponent(q) + "&include_adult=false&page=1")
  }

  function handleSearch(raw) {
    // A response that is no longer for what is typed is discarded outright,
    // otherwise a slow early request can clobber a fast later one.
    if (root.inFlightQuery !== root.queryText.trim()) {
      root.searchLoading = false
      return
    }
    root.searchLoading = false
    root.searchDone = true
    root.resultsQuery = root.inFlightQuery
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) {
        root.results = []
        root.searchError = err
        return
      }
      var list = data.results || []
      // TMDB mixes in media types the panel has no screen for; drop them so
      // the result count matches what is actually browsable.
      root.results = list.filter(function(r) {
        return r.media_type === "movie" || r.media_type === "tv" || r.media_type === "person"
      })
      root.searchError = ""
    } catch (e) {
      root.results = []
      root.searchError = "Failed to read TMDB response"
    }
  }

  // ---------------------------------------------------------------- movie
  function fetchMovie(id) {
    var key = "movie:" + id
    if (root.movieCache[key]) {
      root.movie = root.movieCache[key]
      root.movieLoading = false
      root.movieError = ""
      // A cache hit skips handleMovie, so history is stamped here too.
      root.recordHistory("movie", root.movie.id, root.movie.title || "", root.movie.poster_path || "")
      return
    }
    root.movie = null
    root.movieError = ""
    root.movieLoading = true
    if (!root.apiKeyLoaded || movieProc.running) {
      root.pendingMovieId = id
      return
    }
    if (!root.apiKey) {
      root.movieLoading = false
      root.movieError = "API key not configured in ~/.config/omatv/.env"
      return
    }
    root.pendingMovieId = 0
    root.inFlightMovieId = id
    root.startRequest(movieProc, "/movie/" + id, "append_to_response=credits")
  }

  function handleMovie(raw) {
    if (root.inFlightMovieId !== root.detailId) {
      root.movieLoading = false
      return
    }
    root.movieLoading = false
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) { root.movieError = err; return }
      var next = Object.assign({}, root.movieCache)
      next["movie:" + data.id] = data
      root.movieCache = next
      root.movie = data
      root.movieError = ""
      root.recordHistory("movie", data.id, data.title || data.name || "", data.poster_path || "")
    } catch (e) {
      root.movieError = "Failed to read TMDB response"
    }
  }

  function movieCrew(job) {
    if (!root.movie || !root.movie.credits) return []
    return (root.movie.credits.crew || []).filter(function(c) { return c.job === job })
  }

  function movieDirectors() {
    return root.movieCrew("Director").map(function(c) { return c.name })
  }

  function movieWriters() {
    var jobs = ["Screenplay", "Writer", "Story"]
    var seen = {}
    var out = []
    if (!root.movie || !root.movie.credits) return out
    var crew = root.movie.credits.crew || []
    for (var i = 0; i < crew.length; i++) {
      if (jobs.indexOf(crew[i].job) !== -1 && !seen[crew[i].name]) {
        seen[crew[i].name] = true
        out.push(crew[i].name)
      }
    }
    return out
  }

  readonly property var movieCast: {
    if (!root.movie || !root.movie.credits) return []
    return (root.movie.credits.cast || []).slice(0, 12)
  }

  // ---------------------------------------------------------------- tv
  function fetchTv(id) {
    var key = "tv:" + id
    if (root.tvCache[key]) {
      root.tv = root.tvCache[key]
      root.tvLoading = false
      root.tvError = ""
      root.recordHistory("tv", root.tv.id, root.tv.name || "", root.tv.poster_path || "")
      return
    }
    root.tv = null
    root.tvError = ""
    root.tvLoading = true
    if (!root.apiKeyLoaded || tvProc.running) {
      root.pendingTvId = id
      return
    }
    if (!root.apiKey) {
      root.tvLoading = false
      root.tvError = "API key not configured in ~/.config/omatv/.env"
      return
    }
    root.pendingTvId = 0
    root.inFlightTvId = id
    root.startRequest(tvProc, "/tv/" + id, "append_to_response=aggregate_credits")
  }

  function handleTv(raw) {
    if (root.inFlightTvId !== root.detailId) {
      root.tvLoading = false
      return
    }
    root.tvLoading = false
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) { root.tvError = err; return }
      var next = Object.assign({}, root.tvCache)
      next["tv:" + data.id] = data
      root.tvCache = next
      root.tv = data
      root.tvError = ""
      root.recordHistory("tv", data.id, data.name || "", data.poster_path || "")
    } catch (e) {
      root.tvError = "Failed to read TMDB response"
    }
  }

  // aggregate_credits gives one entry per person with every character they
  // played across the run, which is what the "26 Episodes" line needs.
  readonly property var tvCast: {
    if (!root.tv || !root.tv.aggregate_credits) return []
    return (root.tv.aggregate_credits.cast || []).slice(0, 12)
  }

  function tvRoleName(entry) {
    var roles = entry.roles || []
    return roles.map(function(r) { return r.character }).filter(function(c) { return !!c }).join(", ")
  }

  function episodeCountText(n) {
    var v = Number(n) || 0
    if (v <= 0) return ""
    return v + " Episode" + (v === 1 ? "" : "s")
  }

  // TMDB lists specials as season 0 and orders seasons ascending, so the
  // "current" season is the last numbered one rather than simply the last.
  readonly property var currentSeason: {
    if (!root.tv) return null
    var seasons = (root.tv.seasons || []).filter(function(s) { return Number(s.season_number) > 0 })
    if (seasons.length === 0) return null
    return seasons[seasons.length - 1]
  }

  readonly property var tvNetwork: {
    if (!root.tv) return null
    var nets = root.tv.networks || []
    return nets.length > 0 ? nets[0] : null
  }

  function seasonEpisodeLine() {
    if (!root.tv) return ""
    var ep = root.tv.next_episode_to_air || root.tv.last_episode_to_air
    if (!ep) return ""
    var code = ep.season_number + "x" + ep.episode_number
    var when = ep.air_date || ""
    var label = root.tv.next_episode_to_air ? "Next" : "Last"
    return label + ": " + (ep.name || "") + "  (" + code + (when ? ", " + when : "") + ")"
  }

  // ---------------------------------------------------------------- person
  function fetchPerson(id) {
    var key = "person:" + id
    root.bioExpanded = false
    if (root.personCache[key]) {
      root.person = root.personCache[key]
      root.personLoading = false
      root.personError = ""
      root.recordHistory("person", root.person.id, root.person.name || "", root.person.profile_path || "")
      return
    }
    root.person = null
    root.personError = ""
    root.personLoading = true
    if (!root.apiKeyLoaded || personProc.running) {
      root.pendingPersonId = id
      return
    }
    if (!root.apiKey) {
      root.personLoading = false
      root.personError = "API key not configured in ~/.config/omatv/.env"
      return
    }
    root.pendingPersonId = 0
    root.inFlightPersonId = id
    root.startRequest(personProc, "/person/" + id, "append_to_response=combined_credits")
  }

  function handlePerson(raw) {
    if (root.inFlightPersonId !== root.detailId) {
      root.personLoading = false
      return
    }
    root.personLoading = false
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) { root.personError = err; return }
      var next = Object.assign({}, root.personCache)
      next["person:" + data.id] = data
      root.personCache = next
      root.person = data
      root.personError = ""
      root.recordHistory("person", data.id, data.name || "", data.profile_path || "")
    } catch (e) {
      root.personError = "Failed to read TMDB response"
    }
  }

  function genderLabel(g) {
    var n = Number(g)
    if (n === 1) return "Female"
    if (n === 2) return "Male"
    if (n === 3) return "Non-binary"
    return "—"
  }

  function ageFrom(birthday, deathday) {
    var b = String(birthday || "")
    if (b.length < 10) return 0
    var birth = new Date(b)
    var end = deathday ? new Date(String(deathday)) : new Date()
    var age = end.getFullYear() - birth.getFullYear()
    var m = end.getMonth() - birth.getMonth()
    if (m < 0 || (m === 0 && end.getDate() < birth.getDate())) age--
    return age
  }

  readonly property var monthNames: ["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"]

  function longDate(dateStr) {
    var s = String(dateStr || "")
    if (s.length < 10) return ""
    var parts = s.split("-")
    var mi = Number(parts[1]) - 1
    if (mi < 0 || mi > 11) return s
    return root.monthNames[mi] + " " + Number(parts[2]) + ", " + parts[0]
  }

  function birthdayText() {
    if (!root.person || !root.person.birthday) return "—"
    var base = root.longDate(root.person.birthday)
    if (root.person.deathday) {
      return base + " – " + root.longDate(root.person.deathday)
        + " (" + root.ageFrom(root.person.birthday, root.person.deathday) + " years old)"
    }
    return base + " (" + root.ageFrom(root.person.birthday, null) + " years old)"
  }

  // combined_credits ranked purely by popularity floods the list with talk
  // show and awards appearances, which is not what "Known For" means. Drop
  // self-appearances and the talk/news/reality genres, collapse the duplicate
  // rows TMDB returns per episode-credit, then take the most popular eight.
  // Card metrics for the horizontal strips. cardStripHeight adds room for the
  // text lines under the 2:3 poster; three-line cards (episode count, year)
  // need one more line than two-line ones.
  readonly property int cardWidth: Style.space(88)
  readonly property int cardPosterHeight: Math.round(root.cardWidth * 1.5)
  readonly property int cardStrip2: root.cardPosterHeight + Style.space(74)
  readonly property int cardStrip3: root.cardPosterHeight + Style.space(90)

  readonly property var nonFictionGenres: [10767, 10763, 10764]

  readonly property var knownFor: {
    if (!root.person || !root.person.combined_credits) return []
    var cast = root.person.combined_credits.cast || []
    var seen = {}
    var out = []
    for (var i = 0; i < cast.length; i++) {
      var c = cast[i]
      var character = String(c.character || "")
      if (/^(self|himself|herself)/i.test(character)) continue

      var genres = c.genre_ids || []
      var isNonFiction = false
      for (var g = 0; g < genres.length; g++) {
        if (root.nonFictionGenres.indexOf(genres[g]) !== -1) { isNonFiction = true; break }
      }
      if (isNonFiction) continue

      var key = c.media_type + ":" + c.id
      if (seen[key]) continue
      seen[key] = true
      out.push(c)
    }
    out.sort(function(a, b) { return (Number(b.popularity) || 0) - (Number(a.popularity) || 0) })
    return out.slice(0, 8)
  }

  // ---------------------------------------------------------------- auth flow
  function sessionPath() {
    return Quickshell.env("HOME") + "/.config/omatv/session.json"
  }

  function parseSession(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      root.sessionId = String(data.session_id || "")
      root.accountId = Number(data.account_id) || 0
      root.accountName = String(data.username || "")
      if (root.connected) root.authState = "connected"
    } catch (e) {
      root.sessionId = ""
      root.accountId = 0
      root.accountName = ""
    }
    root.sessionLoaded = true
  }

  // The session id is a bearer credential for the whole account, so the file has
  // to *start* life at 0600 rather than be corrected afterwards. Writing it with
  // FileView and then spawning chmod left a window where the credential sat on
  // disk world-readable, and left it that way for good if the chmod failed.
  // sessionWriteProc creates it under `umask 077` in a temporary file and
  // renames it into place, so a readable copy of the secret never exists.
  function saveSession() {
    if (sessionWriteProc.running) return
    sessionWriteProc.payload = JSON.stringify({
      session_id: root.sessionId,
      account_id: root.accountId,
      username: root.accountName
    }, null, 2)
    // stdinEnabled has to be turned on here, immediately before running, and
    // off again in onStarted. Leaving it on as a declarative binding does not
    // deliver EOF, so `cat` blocks forever and the rename never happens.
    sessionWriteProc.stdinEnabled = true
    sessionWriteProc.running = true
  }

  function connectStart() {
    if (!root.apiKeyLoaded || !root.apiKey) {
      root.authError = "Set API_KEY in ~/.config/omatv/.env first"
      root.authState = "error"
      return
    }
    if (tokenProc.running) return
    root.authError = ""
    root.requestToken = ""
    root.authState = "requesting"
    root.startRequest(tokenProc, "/authentication/token/new", "")
  }

  function handleToken(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) {
        root.authError = err
        root.authState = "error"
        return
      }
      root.requestToken = String(data.request_token || "")
      if (!root.requestToken) {
        root.authError = "TMDB did not return a request token"
        root.authState = "error"
        return
      }
      root.authState = "awaiting"
      root.openApproval()
    } catch (e) {
      root.authError = "Failed to read TMDB response"
      root.authState = "error"
    }
  }

  // The approval page carries only the request token — never the API key or
  // the session id — so it is safe to hand to the browser.
  function openApproval() {
    if (!root.requestToken) return
    browserProc.command = ["xdg-open",
      "https://www.themoviedb.org/authenticate/" + root.requestToken]
    browserProc.running = true
  }

  function connectFinish() {
    if (!root.requestToken || sessionProc.running) return
    root.authError = ""
    root.authState = "exchanging"
    root.startRequest(sessionProc, "/authentication/session/new",
      "request_token=" + encodeURIComponent(root.requestToken), "POST")
  }

  function handleNewSession(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) {
        // Status 17 is TMDB's "you have not approved this token yet", which is
        // the one failure the user can fix without starting over.
        root.authError = (Number(data.status_code) === 17)
          ? "Not approved yet — approve in the browser, then press Continue"
          : err
        root.authState = "awaiting"
        return
      }
      root.sessionId = String(data.session_id || "")
      if (!root.sessionId) {
        root.authError = "TMDB did not return a session id"
        root.authState = "error"
        return
      }
      root.requestToken = ""
      root.fetchAccount()
    } catch (e) {
      root.authError = "Failed to read TMDB response"
      root.authState = "error"
    }
  }

  function fetchAccount() {
    if (!root.sessionId || accountProc.running) return
    root.startRequest(accountProc, "/account",
      "session_id=" + encodeURIComponent(root.sessionId))
  }

  function handleAccount(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) {
        root.authError = err
        root.authState = "error"
        return
      }
      root.accountId = Number(data.id) || 0
      root.accountName = String(data.username || data.name || "")
      root.authState = root.connected ? "connected" : "error"
      if (root.connected) {
        root.authError = ""
        root.saveSession()
      } else {
        root.authError = "TMDB did not return an account id"
      }
    } catch (e) {
      root.authError = "Failed to read TMDB response"
      root.authState = "error"
    }
  }

  function disconnect() {
    // Ask TMDB to invalidate the session as well as forgetting it locally, so a
    // copied session.json cannot outlive the disconnect.
    if (root.sessionId && !deleteSessionProc.running) {
      root.startRequest(deleteSessionProc, "/authentication/session",
        "session_id=" + encodeURIComponent(root.sessionId), "DELETE")
    }
    root.sessionId = ""
    root.accountId = 0
    root.accountName = ""
    root.requestToken = ""
    root.authState = "idle"
    root.authError = ""
    root.saveSession()
  }

  // ---------------------------------------------------------------- account lists
  // Favorites and Watchlist are the only screens whose data costs an API call
  // per view, so they are never polled. The four lists are fetched once, cached
  // to disk, and refreshed only when the user asks (button or `r`).
  property var favMovies: []
  property var favTv: []
  property var watchMovies: []
  property var watchTv: []
  property double listsFetchedAt: 0
  property bool listsLoading: false
  property string listsError: ""
  property bool listsLoaded: false
  property string listTab: "movie"

  // Four endpoints share one Process, walked in order so the panel makes one
  // request at a time instead of four bursts against the rate limit.
  readonly property var listSpecs: [
    { key: "favMovies",   path: "/favorite/movies"  },
    { key: "favTv",       path: "/favorite/tv"      },
    { key: "watchMovies", path: "/watchlist/movies" },
    { key: "watchTv",     path: "/watchlist/tv"     }
  ]
  property int listStep: -1
  property int listPage: 1
  property var listAccum: []
  // TMDB pages account lists at 20 per request, so a watchlist of 44 shows needs
  // three calls. Capped so a pathologically long list cannot fan out forever.
  readonly property int listMaxPages: 5

  function listsCachePath() {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    var base = (xdg && xdg.length > 0) ? xdg : (Quickshell.env("HOME") + "/.cache")
    return base + "/omatv/account.json"
  }

  function parseLists(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      root.favMovies = data.favMovies || []
      root.favTv = data.favTv || []
      root.watchMovies = data.watchMovies || []
      root.watchTv = data.watchTv || []
      root.listsFetchedAt = Number(data.fetchedAt) || 0
      root.listsLoaded = root.listsFetchedAt > 0
    } catch (e) {
      root.listsLoaded = false
    }
  }

  function saveLists() {
    listsFile.setText(JSON.stringify({
      fetchedAt: root.listsFetchedAt,
      favMovies: root.favMovies,
      favTv: root.favTv,
      watchMovies: root.watchMovies,
      watchTv: root.watchTv
    }))
  }

  function refreshLists() {
    if (!root.connected) {
      root.listsError = "Connect your TMDB account first"
      return
    }
    if (root.listsLoading || listProc.running) return
    root.listsError = ""
    root.listsLoading = true
    root.listStep = 0
    root.listPage = 1
    root.listAccum = []
    root.fetchListStep()
  }

  function fetchListStep() {
    if (root.listStep < 0 || root.listStep >= root.listSpecs.length) {
      root.listsLoading = false
      root.listStep = -1
      root.listsFetchedAt = Date.now()
      root.listsLoaded = true
      root.saveLists()
      return
    }
    var spec = root.listSpecs[root.listStep]
    root.startRequest(listProc, "/account/" + root.accountId + spec.path,
      "session_id=" + encodeURIComponent(root.sessionId)
        + "&sort_by=created_at.desc&page=" + root.listPage)
  }

  function abortLists(message) {
    root.listsError = message
    root.listsLoading = false
    root.listStep = -1
    root.listPage = 1
    root.listAccum = []
  }

  function handleListStep(raw) {
    if (root.listStep < 0 || root.listStep >= root.listSpecs.length) return
    var spec = root.listSpecs[root.listStep]
    try {
      var data = JSON.parse(String(raw || ""))
      var err = root.tmdbError(data)
      if (err) { root.abortLists(err); return }

      // The account endpoints omit media_type, unlike /search/multi, so it is
      // stamped here: the result rows and navigation both key off it.
      var mediaType = (spec.path.indexOf("/tv") !== -1) ? "tv" : "movie"
      var page = (data.results || []).map(function(r) {
        r.media_type = mediaType
        return r
      })
      root.listAccum = root.listAccum.concat(page)

      var totalPages = Number(data.total_pages) || 1
      if (root.listPage < totalPages && root.listPage < root.listMaxPages) {
        root.listPage = root.listPage + 1
        Qt.callLater(root.fetchListStep)
        return
      }
    } catch (e) {
      root.abortLists("Failed to read TMDB response")
      return
    }

    root[spec.key] = root.listAccum
    root.listAccum = []
    root.listPage = 1
    root.listStep = root.listStep + 1
    Qt.callLater(root.fetchListStep)
  }

  readonly property var favorites: root.listTab === "tv" ? root.favTv : root.favMovies
  readonly property var watchlist: root.listTab === "tv" ? root.watchTv : root.watchMovies

  // ---------------------------------------------------------------- toggles
  // Adding/removing from Favorites or Watchlist patches the local cache
  // in-place and shows the change immediately, rather than re-fetching the
  // whole (paginated) list for a single item. A failed request rolls the
  // patch back to what the cache held before the click, so the button never
  // ends up lying about the real account state.
  property string favActionType: ""
  property int favActionId: 0
  property bool favActionAdd: false
  property var favActionStash: null
  property bool favActionPending: false

  property string watchActionType: ""
  property int watchActionId: 0
  property bool watchActionAdd: false
  property var watchActionStash: null
  property bool watchActionPending: false

  property string actionError: ""

  function findInList(list, mediaType, id) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].media_type === mediaType && Number(list[i].id) === Number(id)) return i
    }
    return -1
  }

  function isFavorited(mediaType, id) {
    var list = mediaType === "tv" ? root.favTv : root.favMovies
    return root.findInList(list, mediaType, id) !== -1
  }

  function isWatchlisted(mediaType, id) {
    var list = mediaType === "tv" ? root.watchTv : root.watchMovies
    return root.findInList(list, mediaType, id) !== -1
  }

  function isFavoriteBusy(mediaType, id) {
    return root.favActionPending && root.favActionType === mediaType && root.favActionId === id
  }

  function isWatchlistBusy(mediaType, id) {
    return root.watchActionPending && root.watchActionType === mediaType && root.watchActionId === id
  }

  // A slim copy of just the fields the account-list rows render (title,
  // poster, score, date). root.movie/root.tv also carry the full credits
  // payload, which has no business being duplicated into the cached list.
  function slimMedia(mediaType, source) {
    return {
      media_type: mediaType,
      id: source.id,
      title: source.title || "",
      name: source.name || "",
      poster_path: source.poster_path || "",
      vote_average: source.vote_average || 0,
      release_date: source.release_date || "",
      first_air_date: source.first_air_date || ""
    }
  }

  function applyListMembership(listKey, mediaType, id, add, itemData) {
    var list = root[listKey].slice()
    var idx = root.findInList(list, mediaType, id)
    if (add) {
      if (idx === -1) list.unshift(root.slimMedia(mediaType, itemData))
    } else if (idx !== -1) {
      list.splice(idx, 1)
    }
    root[listKey] = list
    root.saveLists()
  }

  function toggleFavorite(mediaType, id, itemData) {
    if (!root.connected) { root.pushView("account", 0); return }
    if (root.favActionPending) return
    root.actionError = ""
    var listKey = mediaType === "tv" ? "favTv" : "favMovies"
    var idx = root.findInList(root[listKey], mediaType, id)
    var willAdd = idx === -1
    root.favActionType = mediaType
    root.favActionId = id
    root.favActionAdd = willAdd
    root.favActionStash = willAdd ? null : root[listKey][idx]
    root.favActionPending = true
    root.applyListMembership(listKey, mediaType, id, willAdd, itemData)
    root.startRequest(actionFavProc, "/account/" + root.accountId + "/favorite",
      "session_id=" + encodeURIComponent(root.sessionId), "POST",
      { media_type: mediaType, media_id: id, favorite: willAdd })
  }

  // Guarded by favActionPending so a late onExited (after onStreamFinished
  // already resolved it) or an onExited that fires with no stdout cannot
  // apply the revert twice.
  function finishFavoriteAction(raw) {
    if (!root.favActionPending) return
    root.favActionPending = false
    var mediaType = root.favActionType, id = root.favActionId, willAdd = root.favActionAdd
    var listKey = mediaType === "tv" ? "favTv" : "favMovies"
    var ok = false
    try {
      var data = JSON.parse(String(raw || ""))
      ok = !root.tmdbError(data)
    } catch (e) { ok = false }
    if (!ok) {
      if (willAdd) root.applyListMembership(listKey, mediaType, id, false, null)
      else if (root.favActionStash) root.applyListMembership(listKey, mediaType, id, true, root.favActionStash)
      root.actionError = "Could not update Favorites \u2014 try again"
    }
    root.favActionStash = null
  }

  function toggleWatchlist(mediaType, id, itemData) {
    if (!root.connected) { root.pushView("account", 0); return }
    if (root.watchActionPending) return
    root.actionError = ""
    var listKey = mediaType === "tv" ? "watchTv" : "watchMovies"
    var idx = root.findInList(root[listKey], mediaType, id)
    var willAdd = idx === -1
    root.watchActionType = mediaType
    root.watchActionId = id
    root.watchActionAdd = willAdd
    root.watchActionStash = willAdd ? null : root[listKey][idx]
    root.watchActionPending = true
    root.applyListMembership(listKey, mediaType, id, willAdd, itemData)
    root.startRequest(actionWatchProc, "/account/" + root.accountId + "/watchlist",
      "session_id=" + encodeURIComponent(root.sessionId), "POST",
      { media_type: mediaType, media_id: id, watchlist: willAdd })
  }

  function finishWatchlistAction(raw) {
    if (!root.watchActionPending) return
    root.watchActionPending = false
    var mediaType = root.watchActionType, id = root.watchActionId, willAdd = root.watchActionAdd
    var listKey = mediaType === "tv" ? "watchTv" : "watchMovies"
    var ok = false
    try {
      var data = JSON.parse(String(raw || ""))
      ok = !root.tmdbError(data)
    } catch (e) { ok = false }
    if (!ok) {
      if (willAdd) root.applyListMembership(listKey, mediaType, id, false, null)
      else if (root.watchActionStash) root.applyListMembership(listKey, mediaType, id, true, root.watchActionStash)
      root.actionError = "Could not update Watchlist \u2014 try again"
    }
    root.watchActionStash = null
  }



  function lastUpdatedText() {
    if (!root.listsFetchedAt) return "never refreshed"
    var diff = Date.now() - root.listsFetchedAt
    var mins = Math.floor(diff / 60000)
    if (mins < 1) return "updated just now"
    if (mins < 60) return "updated " + mins + "m ago"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return "updated " + hours + "h ago"
    return "updated " + Math.floor(hours / 24) + "d ago"
  }

  // ---------------------------------------------------------------- history
  // The last 10 detail screens opened, newest first, persisted so the list
  // survives a shell restart. Re-opening an entry moves it back to the top
  // rather than adding a duplicate.
  property var history: []
  readonly property int historyLimit: 10

  function historyCachePath() {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    var base = (xdg && xdg.length > 0) ? xdg : (Quickshell.env("HOME") + "/.cache")
    return base + "/omatv/history.json"
  }

  function parseHistory(raw) {
    try {
      var data = JSON.parse(String(raw || "[]"))
      root.history = Array.isArray(data) ? data.slice(0, root.historyLimit) : []
    } catch (e) {
      root.history = []
    }
  }

  function saveHistory() {
    historyFile.setText(JSON.stringify(root.history))
  }

  function recordHistory(mediaType, id, title, posterPath) {
    if (!id || !title) return
    var key = mediaType + ":" + id
    var next = [{
      media_type: mediaType,
      id: id,
      title: title,
      poster_path: posterPath || "",
      seenAt: Date.now()
    }]
    for (var i = 0; i < root.history.length; i++) {
      var h = root.history[i]
      if (h.media_type + ":" + h.id === key) continue
      next.push(h)
      if (next.length >= root.historyLimit) break
    }
    root.history = next
    root.saveHistory()
  }

  function clearHistory() {
    root.history = []
    root.saveHistory()
  }

  function historyWhen(ts) {
    var diff = Date.now() - (Number(ts) || 0)
    var mins = Math.floor(diff / 60000)
    if (mins < 1) return "just now"
    if (mins < 60) return mins + "m ago"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  // ---------------------------------------------------------------- selection
  // With the key catcher holding focus, j/k (or the arrows) move a selection
  // through the current list and Enter opens it, so the panel is usable without
  // reaching for the mouse.
  property int selectedIndex: 0

  readonly property var activeList: {
    if (root.view === "search") return root.filteredResults
    if (root.view === "favorites") return root.favorites
    if (root.view === "watchlist") return root.watchlist
    if (root.view === "history") return root.history
    return []
  }

  function moveSelection(delta) {
    var list = root.activeList
    if (list.length === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next > list.length - 1) next = list.length - 1
    root.selectedIndex = next
  }

  function activateSelection() {
    var list = root.activeList
    if (list.length === 0) return
    var item = list[Math.max(0, Math.min(root.selectedIndex, list.length - 1))]
    if (item) root.openResult(item)
  }

  // Any change of list or screen starts the selection over, so it never points
  // past the end of a shorter list.
  onActiveListChanged: root.selectedIndex = 0

  // Changing screen always hands focus back to the key catcher. Without this a
  // search field that still holds focus keeps the catcher `blocked`, which
  // silently kills every shortcut on every screen, however you navigated there.
  onViewChanged: {
    root.selectedIndex = 0
    root.actionError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---------------------------------------------------------------- navigation
  function loadView(which, id) {
    if (!id) return
    if (which === "movie") root.fetchMovie(id)
    else if (which === "tv") root.fetchTv(id)
    else if (which === "person") root.fetchPerson(id)
  }

  // Opening a list never triggers a network call on its own: the on-disk cache
  // is what is shown, and only a completely empty cache kicks off one fetch.
  function openList(which) {
    root.pushView(which, 0)
    if (root.connected && !root.listsLoaded && !root.listsLoading) root.refreshLists()
  }

  function pushView(nextView, id) {
    root.navStack = root.navStack.concat([{ view: root.view, id: root.detailId }])
    root.view = nextView
    root.detailId = id || 0
    root.loadView(nextView, id)
  }

  function popView() {
    if (root.navStack.length === 0) {
      root.close()
      return
    }
    var prev = root.navStack[root.navStack.length - 1]
    root.navStack = root.navStack.slice(0, -1)
    root.view = prev.view
    root.detailId = prev.id
    root.loadView(prev.view, prev.id)
  }

  function openResult(r) {
    if (root.canOpen(r)) root.pushView(r.media_type, r.id)
  }

  function canOpen(r) {
    var t = r.media_type
    return t === "movie" || t === "tv" || t === "person"
  }

  function triggerPress(button) {
    if (root.opened) root.close()
    else root.open()
  }

  // ---------------------------------------------------------------- components
  component FactRow: ColumnLayout {
    id: factRow
    property string label: ""
    property string value: ""
    visible: factRow.value !== "" && factRow.value !== "—"
    spacing: 1
    Layout.fillWidth: true

    Text {
      text: factRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      text: factRow.value
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      Layout.fillWidth: true
      wrapMode: Text.WordWrap
    }
  }

  // Used both for the search type filter and the Movies/TV split inside the
  // account lists, so which selection it reflects is passed in rather than
  // hard-wired to one property.
  component FilterTab: Text {
    id: filterTab
    property string filterKey: ""
    property string filterLabel: ""
    property bool active: root.typeFilter === filterTab.filterKey
    signal picked()

    text: filterTab.filterLabel
    color: filterTab.active ? Color.accent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: filterTab.active

    MouseArea {
      anchors.fill: parent
      anchors.margins: -4
      cursorShape: Qt.PointingHandCursor
      onClicked: filterTab.picked()
    }
  }

  // Poster/photo tile with a placeholder glyph while the image loads or when
  // TMDB has no artwork for the entry.
  component Poster: Rectangle {
    id: poster
    property string path: ""
    property string size: "w185"
    property string fallbackIcon: ""
    radius: Style.space(4)
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
    clip: true

    Text {
      anchors.centerIn: parent
      visible: posterImage.status !== Image.Ready
      text: poster.fallbackIcon
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Image {
      id: posterImage
      anchors.fill: parent
      source: root.imgUrl(poster.path, poster.size)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      smooth: true
    }
  }

  // Shared card for the horizontally scrolling strips: movie cast, series cast
  // and a person's Known For all use it, differing only in the two text lines.
  component MediaCard: Rectangle {
    id: mediaCard
    property string path: ""
    property string title: ""
    property string subtitle: ""
    property string extra: ""
    property string fallbackIcon: ""
    property bool clickable: false
    signal activated()

    radius: Style.space(6)
    color: (mediaCard.clickable && cardHover.containsMouse)
      ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.13)
      : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
    border.width: 1
    border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
    clip: true

    MouseArea {
      id: cardHover
      anchors.fill: parent
      hoverEnabled: true
      enabled: mediaCard.clickable
      cursorShape: Qt.PointingHandCursor
      onClicked: mediaCard.activated()
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: 0

      // TMDB posters and profile shots are both 2:3. Deriving the height from
      // the card width keeps that ratio, so PreserveAspectCrop has nothing to
      // crop and the artwork is shown whole.
      Poster {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.round(mediaCard.width * 1.5)
        radius: 0
        path: mediaCard.path
        size: "w185"
        fallbackIcon: mediaCard.fallbackIcon
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.margins: Style.space(6)
        spacing: 1

        Text {
          Layout.fillWidth: true
          text: mediaCard.title
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: mediaCard.subtitle !== ""
          text: mediaCard.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Item { Layout.fillHeight: true }

        Text {
          id: extraLine
          Layout.fillWidth: true
          // Pinned to its natural height: without a minimum the layout
          // collapses this line instead of the flexible spacer above it, and
          // the episode count silently vanishes.
          Layout.minimumHeight: mediaCard.extra !== "" ? extraLine.implicitHeight : 0
          visible: mediaCard.extra !== ""
          text: mediaCard.extra
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // Vertical result rows, shared by search, favorites, watchlist and history.
  component ResultRows: ListView {
    id: rows
    property var items: []
    property bool showWhen: false
    // Only the list belonging to the visible screen should draw a selection.
    property bool selectable: true
    readonly property int selected: rows.selectable ? root.selectedIndex : -1
    clip: true

    onSelectedChanged: if (rows.selected >= 0) rows.positionViewAtIndex(rows.selected, ListView.Contain)
    spacing: Style.space(6)
    model: rows.items
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    delegate: Rectangle {
      id: row
      required property var modelData
      required property int index
      width: rows.width
      height: rowBody.implicitHeight + Style.space(10)
      radius: Style.space(6)
      readonly property bool isSelected: rows.selected === index
      color: (rowMouse.containsMouse || row.isSelected)
        ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
        : "transparent"
      border.width: row.isSelected ? 1 : 0
      border.color: Color.accent

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.canOpen(row.modelData) ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.openResult(row.modelData)
      }

      RowLayout {
        id: rowBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(5)
        anchors.rightMargin: Style.space(5)
        spacing: Style.space(10)

        Poster {
          Layout.preferredWidth: 34
          Layout.preferredHeight: 50
          path: root.resultPoster(row.modelData)
          size: "w92"
          fallbackIcon: root.mediaIcon(row.modelData.media_type)
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 2

          Text {
            Layout.fillWidth: true
            text: root.resultTitle(row.modelData)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            // History rows carry no rating or release date, so the parts are
            // joined only when they actually exist \u2014 otherwise the row reads
            // as a stray separator next to the icon.
            text: {
              var parts = [root.resultMeta(row.modelData)]
              if (rows.showWhen && row.modelData.seenAt) {
                parts.push(root.historyWhen(row.modelData.seenAt))
              }
              var meta = parts.filter(function(p) { return !!p }).join("  \u00b7  ")
              var icon = root.mediaIcon(row.modelData.media_type)
              return meta ? (icon + "  " + meta) : icon
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          visible: root.canOpen(row.modelData)
          text: "\uf054"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---------------------------------------------------------------- io
  FileView {
    id: envFile
    path: Quickshell.env("HOME") + "/.config/omatv/.env"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.parseEnv(text())
      // Re-assert 0600 on every load: the file holds the TMDB key and nothing
      // else in the plugin guarantees its mode.
      envPermProc.command = ["chmod", "600", envFile.path]
      envPermProc.running = true
    }
    onLoadFailed: {
      root.apiKeyLoaded = true
      root.searchError = "~/.config/omatv/.env not found (see README)"
    }
  }

  Process {
    id: envPermProc
  }

  Process {
    id: searchProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSearch(text)
    }
    onStarted: {
      searchProc.write(searchProc.reqConfig)
      searchProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) {
        root.searchLoading = false
        root.searchDone = true
        root.searchError = "TMDB request failed"
      }
      Qt.callLater(root.flushPending)
    }
  }

  Process {
    id: movieProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleMovie(text)
    }
    onStarted: {
      movieProc.write(movieProc.reqConfig)
      movieProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) {
        root.movieLoading = false
        root.movieError = "TMDB request failed"
      }
      Qt.callLater(root.flushPending)
    }
  }

  Process {
    id: tvProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleTv(text)
    }
    onStarted: {
      tvProc.write(tvProc.reqConfig)
      tvProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) {
        root.tvLoading = false
        root.tvError = "TMDB request failed"
      }
      Qt.callLater(root.flushPending)
    }
  }

  Process {
    id: personProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handlePerson(text)
    }
    onStarted: {
      personProc.write(personProc.reqConfig)
      personProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) {
        root.personLoading = false
        root.personError = "TMDB request failed"
      }
      Qt.callLater(root.flushPending)
    }
  }

  // Read-only: the credential is written by sessionWriteProc so that it is
  // created with restrictive permissions in the first place.
  FileView {
    id: sessionFile
    path: root.sessionPath()
    printErrors: false
    onLoaded: {
      root.parseSession(text())
      // A file left behind by an earlier version (or written by hand) may still
      // be world-readable, and creating new files safely does nothing for one
      // that already exists. Tighten it on every load.
      // Also clears a temp file left behind by an interrupted write; it holds
      // the credential too, so it should not outlive the attempt.
      sessionPermFixProc.command = ["sh", "-c",
        'chmod 600 "$1" 2>/dev/null; rm -f "$1.tmp"', "omatv-perm", root.sessionPath()]
      sessionPermFixProc.running = true
    }
    onLoadFailed: root.sessionLoaded = true
  }

  Process {
    id: sessionPermFixProc
  }

  // umask 077 makes the temporary file 0600 at creation; the rename is atomic
  // and carries that mode to the destination, so there is no point at which the
  // credential is readable by another local user.
  // umask 077 makes the temporary file 0600 at creation; the rename is atomic
  // and carries that mode to the destination, so there is no point at which the
  // credential is readable by another local user. The temp name is fixed rather
  // than PID-based so an interrupted write leaves at most one stale file, which
  // the next attempt overwrites.
  Process {
    id: sessionWriteProc
    property string payload: ""
    stdinEnabled: false
    command: ["sh", "-c",
      'umask 077; mkdir -p "$(dirname "$1")" || exit 1; ' +
      'tmp="$1.tmp"; cat > "$tmp" || exit 1; ' +
      'chmod 600 "$tmp" || { rm -f "$tmp"; exit 1; }; ' +
      'mv -f "$tmp" "$1"',
      "omatv-session", root.sessionPath()]
    onStarted: {
      sessionWriteProc.write(sessionWriteProc.payload)
      sessionWriteProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) root.authError = "Could not save the session file securely"
    }
  }

  Process {
    id: actionFavProc
    property string reqConfig: ""
    stdinEnabled: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishFavoriteAction(text)
    }
    onStarted: {
      actionFavProc.write(actionFavProc.reqConfig)
      actionFavProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) root.finishFavoriteAction("")
    }
  }

  Process {
    id: actionWatchProc
    property string reqConfig: ""
    stdinEnabled: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishWatchlistAction(text)
    }
    onStarted: {
      actionWatchProc.write(actionWatchProc.reqConfig)
      actionWatchProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) root.finishWatchlistAction("")
    }
  }

  Process {
    id: tokenProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleToken(text)
    }
    onStarted: {
      tokenProc.write(tokenProc.reqConfig)
      tokenProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0 && root.authState === "requesting") {
        root.authError = "Could not reach TMDB"
        root.authState = "error"
      }
    }
  }

  Process {
    id: sessionProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleNewSession(text)
    }
    onStarted: {
      sessionProc.write(sessionProc.reqConfig)
      sessionProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0 && root.authState === "exchanging") {
        root.authError = "Could not reach TMDB"
        root.authState = "awaiting"
      }
    }
  }

  Process {
    id: accountProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleAccount(text)
    }
    onStarted: {
      accountProc.write(accountProc.reqConfig)
      accountProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0 && !root.connected) {
        root.authError = "Could not reach TMDB"
        root.authState = "error"
      }
    }
  }

  Process {
    id: deleteSessionProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    onStarted: {
      deleteSessionProc.write(deleteSessionProc.reqConfig)
      deleteSessionProc.stdinEnabled = false
    }
  }

  Process {
    id: listProc
    property string reqConfig: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleListStep(text)
    }
    onStarted: {
      listProc.write(listProc.reqConfig)
      listProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0 && root.listsLoading) {
        root.listsLoading = false
        root.listStep = -1
        root.listsError = "Could not reach TMDB"
      }
    }
  }

  FileView {
    id: listsFile
    path: root.listsCachePath()
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onLoaded: root.parseLists(text())
  }

  FileView {
    id: historyFile
    path: root.historyCachePath()
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onLoaded: root.parseHistory(text())
  }

  // The cache directory has to exist before the FileViews can write into it.
  Process {
    id: cacheSetupProc
    command: ["mkdir", "-p", root.listsCachePath().replace(/\/[^\/]*$/, "")]
  }

  Component.onCompleted: cacheSetupProc.running = true

  // Debounced so typing a query does not fire one request per keystroke.
  Timer {
    id: searchDebounce
    interval: 450
    repeat: false
    onTriggered: root.runSearch()
  }

  // The panel opens with the key catcher focused, not the search field, so the
  // single-letter shortcuts work straight away. "/" is what reaches the field.
  onOpenedChanged: {
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }


  // ---------------------------------------------------------------- bar chip
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(34)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    tooltipText: "TMDB — search movies, TV and people"
    onPressed: function(b) { root.triggerPress(b) }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search box has focus every letter belongs to the query, so
      // the shortcuts stay out of the way until focus leaves it.
      blocked: searchField.activeFocus
      onCloseRequested: root.popView()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
      }
      onActivateRequested: root.activateSelection()
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        // PanelKeyCatcher consumes h/j/k/l/x for movement and delete before
        // textKey ever fires, so "viewed" is bound to v rather than h.
        if (k === "r") {
          if (root.view === "favorites" || root.view === "watchlist") root.refreshLists()
          else if (root.view === "search") root.runSearch()
        } else if (k === "f") {
          root.openList("favorites")
        } else if (k === "w") {
          root.openList("watchlist")
        } else if (k === "v") {
          root.pushView("history", 0)
        } else if (k === "a") {
          root.pushView("account", 0)
        } else if (k === "/") {
          if (root.view !== "search") root.pushView("search", 0)
          // Select the previous query so typing replaces it instead of
          // appending to it.
          Qt.callLater(function() {
            searchField.forceActiveFocus()
            searchField.selectAll()
          })
        }
      }
    }

    ColumnLayout {
      id: contentColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)

      // ------------------------------------------------------------ header
      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Text {
          text: root.barIcon + "  OmaTV"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          Layout.fillWidth: true
        }

        Button {
          visible: root.view !== "favorites"
          text: "" // nf-fa-heart
          foreground: root.fg
          tooltipText: "Favorites (f)"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.openList("favorites")
        }

        Button {
          visible: root.view !== "watchlist"
          text: "" // nf-fa-bookmark
          foreground: root.fg
          tooltipText: "Watchlist (w)"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.openList("watchlist")
        }

        Button {
          visible: root.view !== "history"
          text: "" // nf-fa-clock-o
          foreground: root.fg
          tooltipText: "History (v)"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.pushView("history", 0)
        }

        Button {
          visible: root.view !== "account"
          text: root.connected ? "" : "" // nf-fa-user / nf-fa-user-times
          foreground: root.connected ? root.fg : root.dim
          tooltipText: root.connected
            ? ("Connected as " + root.accountName)
            : "Connect your TMDB account"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.pushView("account", 0)
        }

        Button {
          visible: root.navStack.length > 0
          text: "Back"
          foreground: root.fg
          tooltipText: "Back (Esc)"
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.popView()
        }
      }

      // ------------------------------------------------------------ account view
      ColumnLayout {
        visible: root.view === "account"
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          Layout.fillWidth: true
          text: root.connected ? "TMDB Account" : "Connect TMDB"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        // ---- connected
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.connected
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Signed in as " + root.accountName
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            text: "Favorites and Watchlist are available from the search screen. "
              + "The session never expires, so this is a one-time step."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            text: "Disconnect"
            foreground: Color.urgent
            tooltipText: "Invalidate this session on TMDB and forget it locally"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.disconnect()
          }
        }

        // ---- not connected
        ColumnLayout {
          Layout.fillWidth: true
          visible: !root.connected
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Favorites and Watchlist live on your TMDB account, which needs "
              + "a one-time approval in your browser. TMDB sessions do not expire, "
              + "so you only do this once."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: root.authState === "awaiting" || root.authState === "exchanging"
            text: root.authState === "exchanging"
              ? "Exchanging approval for a session…"
              : "Step 2 — approve OmaTV in the browser tab that just opened, then press Continue."
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            Layout.fillWidth: true
            visible: root.authError !== ""
            text: root.authError
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Button {
              visible: root.authState !== "awaiting" && root.authState !== "exchanging"
              text: root.authState === "requesting" ? "Requesting…" : "Connect TMDB"
              foreground: root.fg
              accent: Color.accent
              active: root.authState === "requesting"
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.connectStart()
            }

            Button {
              visible: root.authState === "awaiting"
              text: "Continue"
              foreground: root.fg
              accent: Color.accent
              tooltipText: "I approved it in the browser"
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.connectFinish()
            }

            Button {
              visible: root.authState === "awaiting"
              text: "Reopen link"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.openApproval()
            }

            Button {
              visible: root.authState === "awaiting"
              text: "Cancel"
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: {
                root.requestToken = ""
                root.authState = "idle"
                root.authError = ""
              }
            }
          }

          Text {
            Layout.fillWidth: true
            Layout.topMargin: 2
            text: "The session id is stored in ~/.config/omatv/session.json (0600) "
              + "and is never placed in a command line or a URL you can see."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      // ------------------------------------------------------------ search view
      ColumnLayout {
        visible: root.view === "search"
        Layout.fillWidth: true
        spacing: Style.space(8)

        TextField {
          id: searchField
          Layout.fillWidth: true
          placeholderText: searchField.activeFocus
            ? "Type to search\u2026"
            : "Press / to search"
          foreground: root.fg
          text: root.queryText
          onTextChanged: {
            root.queryText = text
            // Drop the old list immediately rather than leaving it under a
            // query it does not belong to.
            if (root.resultsQuery !== text.trim()) {
              root.results = []
              root.searchDone = false
            }
            searchDebounce.restart()
          }
          // Escape only ever leaves the field, handing focus to the key
          // catcher; the second Escape is the one that goes back or closes.
          // Navigating here would skip a step, because reaching the field with
          // "/" has already pushed the search screen onto the stack.
          Keys.onEscapePressed: keyCatcher.forceActiveFocus()
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          FilterTab { filterKey: "all"; filterLabel: "All"; onPicked: root.typeFilter = "all" }
          FilterTab { filterKey: "movie"; filterLabel: "Movies"; onPicked: root.typeFilter = "movie" }
          FilterTab { filterKey: "tv"; filterLabel: "TV"; onPicked: root.typeFilter = "tv" }
          FilterTab { filterKey: "person"; filterLabel: "People"; onPicked: root.typeFilter = "person" }

          Item { Layout.fillWidth: true }

          Text {
            visible: root.searchLoading
            text: "Searching…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: root.searchError !== ""
          Layout.fillWidth: true
          text: root.searchError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.searchError === "" && root.queryText.trim() === ""
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "Type to search TMDB"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: root.searchError === "" && root.searchDone
            && root.queryText.trim() !== "" && root.filteredResults.length === 0
            && !root.searchLoading
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "No results"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ResultRows {
          id: resultList
          items: root.filteredResults
          selectable: root.view === "search"
          visible: root.filteredResults.length > 0
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(resultList.contentHeight, Style.space(700))
        }
      }

      // ------------------------------------------------------------ movie view
      ColumnLayout {
        visible: root.view === "movie"
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          visible: root.movieError !== ""
          Layout.fillWidth: true
          text: root.movieError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.movieLoading
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "Loading…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flickable {
          id: movieScroll
          visible: root.movie !== null && !root.movieLoading
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(movieBody.implicitHeight, Style.space(760))
          contentWidth: width
          contentHeight: movieBody.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          ColumnLayout {
            id: movieBody
            width: movieScroll.width
            spacing: Style.space(10)

            // ---- hero: poster + title block
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(12)

              Poster {
                Layout.preferredWidth: 110
                Layout.preferredHeight: 165
                Layout.alignment: Qt.AlignTop
                path: root.movie ? root.movie.poster_path : ""
                size: "w185"
                fallbackIcon: ""
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(5)

                Text {
                  Layout.fillWidth: true
                  text: root.movie
                    ? (root.movie.title || "") +
                      (root.yearOf(root.movie.release_date) ? " (" + root.yearOf(root.movie.release_date) + ")" : "")
                    : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  Text {
                    visible: text !== ""
                    text: root.movie ? root.scoreText(root.movie.vote_average) : ""
                    color: root.movie ? root.scoreColor(root.movie.vote_average) : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    Layout.fillWidth: true
                    text: {
                      if (!root.movie) return ""
                      var genres = (root.movie.genres || []).map(function(g) { return g.name }).join(", ")
                      return [root.runtimeText(root.movie.runtime), genres]
                        .filter(function(p) { return !!p }).join("  ·  ")
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  Layout.topMargin: 2
                  visible: root.movie !== null
                  spacing: Style.space(6)

                  Button {
                    iconText: "\uf004" // nf-fa-heart
                    iconSize: Style.font.icon
                    foreground: root.fg
                    accent: Color.accent
                    selected: root.movie ? root.isFavorited("movie", root.movie.id) : false
                    active: root.movie ? root.isFavoriteBusy("movie", root.movie.id) : false
                    tooltipText: (root.movie && root.isFavorited("movie", root.movie.id))
                      ? "Remove from Favorites" : "Add to Favorites"
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: if (root.movie) root.toggleFavorite("movie", root.movie.id, root.movie)
                  }

                  Button {
                    iconText: "\uf02e" // nf-fa-bookmark
                    iconSize: Style.font.icon
                    foreground: root.fg
                    accent: Color.accent
                    selected: root.movie ? root.isWatchlisted("movie", root.movie.id) : false
                    active: root.movie ? root.isWatchlistBusy("movie", root.movie.id) : false
                    tooltipText: (root.movie && root.isWatchlisted("movie", root.movie.id))
                      ? "Remove from Watchlist" : "Add to Watchlist"
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: if (root.movie) root.toggleWatchlist("movie", root.movie.id, root.movie)
                  }

                  Item { Layout.fillWidth: true }
                }

                Text {
                  Layout.fillWidth: true
                  visible: root.actionError !== ""
                  text: root.actionError
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  Layout.fillWidth: true
                  visible: text !== ""
                  text: root.movie ? (root.movie.tagline || "") : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.italic: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  Layout.fillWidth: true
                  Layout.topMargin: 2
                  visible: text !== ""
                  text: root.movie
                    ? [root.movieDirectors().length ? "Director: " + root.movieDirectors().join(", ") : "",
                       root.movieWriters().length ? "Writer: " + root.movieWriters().slice(0, 3).join(", ") : ""]
                      .filter(function(p) { return !!p }).join("\n")
                    : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

            // ---- overview
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.movie && root.movie.overview
              spacing: 2

              Text {
                text: "Overview"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                Layout.fillWidth: true
                text: root.movie ? (root.movie.overview || "") : ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ---- facts
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 2

              Text {
                text: "Facts"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: 3
                columns: 2
                columnSpacing: Style.space(16)
                rowSpacing: Style.space(7)

                FactRow {
                  label: "Status"
                  value: root.movie ? (root.movie.status || "—") : "—"
                }
                FactRow {
                  label: "Original Language"
                  value: root.movie ? root.languageName(root.movie.original_language) : "—"
                }
                FactRow {
                  label: "Budget"
                  value: root.movie ? root.money(root.movie.budget) : "—"
                }
                FactRow {
                  label: "Revenue"
                  value: root.movie ? root.money(root.movie.revenue) : "—"
                }
              }
            }

            // ---- top billed cast, horizontal scroll
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.movieCast.length > 0
              spacing: Style.space(5)

              Text {
                text: "Top Billed Cast"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              ListView {
                id: castList
                Layout.fillWidth: true
                Layout.preferredHeight: root.cardStrip2
                orientation: ListView.Horizontal
                clip: true
                spacing: Style.space(8)
                model: root.movieCast
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: MediaCard {
                  required property var modelData
                  width: root.cardWidth
                  height: castList.height - Style.space(10)
                  path: modelData.profile_path || ""
                  title: modelData.name || ""
                  subtitle: modelData.character || ""
                  fallbackIcon: ""
                  clickable: true
                  onActivated: root.pushView("person", modelData.id)
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ tv view
      ColumnLayout {
        visible: root.view === "tv"
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          visible: root.tvError !== ""
          Layout.fillWidth: true
          text: root.tvError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.tvLoading
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "Loading…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flickable {
          id: tvScroll
          visible: root.tv !== null && !root.tvLoading
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(tvBody.implicitHeight, Style.space(760))
          contentWidth: width
          contentHeight: tvBody.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          ColumnLayout {
            id: tvBody
            width: tvScroll.width
            spacing: Style.space(10)

            // ---- hero
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(12)

              Poster {
                Layout.preferredWidth: 110
                Layout.preferredHeight: 165
                Layout.alignment: Qt.AlignTop
                path: root.tv ? root.tv.poster_path : ""
                size: "w185"
                fallbackIcon: ""
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(5)

                Text {
                  Layout.fillWidth: true
                  text: root.tv
                    ? (root.tv.name || "") +
                      (root.yearOf(root.tv.first_air_date) ? " (" + root.yearOf(root.tv.first_air_date) + ")" : "")
                    : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  Text {
                    visible: text !== ""
                    text: root.tv ? root.scoreText(root.tv.vote_average) : ""
                    color: root.tv ? root.scoreColor(root.tv.vote_average) : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    Layout.fillWidth: true
                    text: {
                      if (!root.tv) return ""
                      var genres = (root.tv.genres || []).map(function(g) { return g.name }).join(", ")
                      var seasons = Number(root.tv.number_of_seasons) || 0
                      var seasonText = seasons > 0 ? (seasons + " Season" + (seasons === 1 ? "" : "s")) : ""
                      return [seasonText, genres].filter(function(p) { return !!p }).join("  ·  ")
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  Layout.topMargin: 2
                  visible: root.tv !== null
                  spacing: Style.space(6)

                  Button {
                    iconText: "\uf004" // nf-fa-heart
                    iconSize: Style.font.icon
                    foreground: root.fg
                    accent: Color.accent
                    selected: root.tv ? root.isFavorited("tv", root.tv.id) : false
                    active: root.tv ? root.isFavoriteBusy("tv", root.tv.id) : false
                    tooltipText: (root.tv && root.isFavorited("tv", root.tv.id))
                      ? "Remove from Favorites" : "Add to Favorites"
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: if (root.tv) root.toggleFavorite("tv", root.tv.id, root.tv)
                  }

                  Button {
                    iconText: "\uf02e" // nf-fa-bookmark
                    iconSize: Style.font.icon
                    foreground: root.fg
                    accent: Color.accent
                    selected: root.tv ? root.isWatchlisted("tv", root.tv.id) : false
                    active: root.tv ? root.isWatchlistBusy("tv", root.tv.id) : false
                    tooltipText: (root.tv && root.isWatchlisted("tv", root.tv.id))
                      ? "Remove from Watchlist" : "Add to Watchlist"
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: if (root.tv) root.toggleWatchlist("tv", root.tv.id, root.tv)
                  }

                  Item { Layout.fillWidth: true }
                }

                Text {
                  Layout.fillWidth: true
                  visible: root.actionError !== ""
                  text: root.actionError
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  Layout.fillWidth: true
                  visible: text !== ""
                  text: root.tv ? (root.tv.tagline || "") : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.italic: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  Layout.fillWidth: true
                  Layout.topMargin: 2
                  visible: text !== ""
                  text: {
                    if (!root.tv) return ""
                    var creators = (root.tv.created_by || []).map(function(c) { return c.name })
                    return creators.length ? "Creator: " + creators.join(", ") : ""
                  }
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

            // ---- overview
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tv && root.tv.overview
              spacing: 2

              Text {
                text: "Overview"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                Layout.fillWidth: true
                text: root.tv ? (root.tv.overview || "") : ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ---- facts: Status / Network (logo) / Type
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 2

              Text {
                text: "Facts"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              GridLayout {
                Layout.fillWidth: true
                Layout.topMargin: 3
                columns: 2
                columnSpacing: Style.space(16)
                rowSpacing: Style.space(7)

                FactRow {
                  label: "Status"
                  value: root.tv ? (root.tv.status || "—") : "—"
                }
                FactRow {
                  label: "Type"
                  value: root.tv ? (root.tv.type || "—") : "—"
                }

                // The network is shown as its logo when TMDB has one, matching
                // the site, and falls back to the plain name when it does not.
                ColumnLayout {
                  Layout.fillWidth: true
                  visible: root.tvNetwork !== null
                  spacing: 2

                  Text {
                    text: "Network"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Image {
                    id: networkLogo
                    visible: status === Image.Ready
                    Layout.preferredHeight: Style.space(22)
                    Layout.preferredWidth: Math.min(
                      implicitWidth * (Style.space(22) / Math.max(1, implicitHeight)),
                      Style.space(110))
                    source: root.tvNetwork ? root.imgUrl(root.tvNetwork.logo_path, "h30") : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                  }

                  Text {
                    visible: networkLogo.status !== Image.Ready
                    text: root.tvNetwork ? (root.tvNetwork.name || "—") : "—"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                FactRow {
                  label: "Original Language"
                  value: root.tv ? root.languageName(root.tv.original_language) : "—"
                }
              }
            }

            // ---- series cast
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tvCast.length > 0
              spacing: Style.space(5)

              Text {
                text: "Series Cast"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              ListView {
                id: tvCastList
                Layout.fillWidth: true
                // One text line taller: these cards carry the episode count.
                Layout.preferredHeight: root.cardStrip3
                orientation: ListView.Horizontal
                clip: true
                spacing: Style.space(8)
                model: root.tvCast
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: MediaCard {
                  required property var modelData
                  width: root.cardWidth
                  height: tvCastList.height - Style.space(10)
                  path: modelData.profile_path || ""
                  title: modelData.name || ""
                  subtitle: root.tvRoleName(modelData)
                  extra: root.episodeCountText(modelData.total_episode_count)
                  fallbackIcon: ""
                  clickable: true
                  onActivated: root.pushView("person", modelData.id)
                }
              }
            }

            // ---- current season
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.currentSeason !== null
              spacing: Style.space(5)

              Text {
                text: "Current Season"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: seasonInner.implicitHeight + Style.space(16)
                radius: Style.space(6)
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
                border.width: 1
                border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

                RowLayout {
                  id: seasonInner
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(10)

                  Poster {
                    Layout.preferredWidth: 62
                    Layout.preferredHeight: 93
                    Layout.alignment: Qt.AlignTop
                    path: root.currentSeason ? root.currentSeason.poster_path : ""
                    size: "w185"
                    fallbackIcon: ""
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 3

                    Text {
                      Layout.fillWidth: true
                      text: root.currentSeason ? (root.currentSeason.name || "") : ""
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(8)

                      Text {
                        visible: text !== ""
                        text: root.currentSeason ? root.scoreText(root.currentSeason.vote_average) : ""
                        color: root.currentSeason ? root.scoreColor(root.currentSeason.vote_average) : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Text {
                        Layout.fillWidth: true
                        text: {
                          if (!root.currentSeason) return ""
                          var year = root.yearOf(root.currentSeason.air_date)
                          var eps = Number(root.currentSeason.episode_count) || 0
                          return [year, eps > 0 ? (eps + " Episodes") : ""]
                            .filter(function(p) { return !!p }).join("  ·  ")
                        }
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      visible: text !== ""
                      text: root.currentSeason ? (root.currentSeason.overview || "") : ""
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                      maximumLineCount: 3
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      Layout.topMargin: 2
                      visible: text !== ""
                      text: root.seasonEpisodeLine()
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ person view
      ColumnLayout {
        visible: root.view === "person"
        Layout.fillWidth: true
        spacing: Style.space(10)

        Text {
          visible: root.personError !== ""
          Layout.fillWidth: true
          text: root.personError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.personLoading
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "Loading…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flickable {
          id: personScroll
          visible: root.person !== null && !root.personLoading
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(personBody.implicitHeight, Style.space(760))
          contentWidth: width
          contentHeight: personBody.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          ColumnLayout {
            id: personBody
            width: personScroll.width
            spacing: Style.space(10)

            // ---- hero: photo + personal info
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(12)

              Poster {
                Layout.preferredWidth: 110
                Layout.preferredHeight: 165
                Layout.alignment: Qt.AlignTop
                path: root.person ? root.person.profile_path : ""
                size: "w185"
                fallbackIcon: ""
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: root.person ? (root.person.name || "") : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                FactRow {
                  label: "Known For"
                  value: root.person ? (root.person.known_for_department || "—") : "—"
                }
                FactRow {
                  label: "Birthday"
                  value: root.birthdayText()
                }
                FactRow {
                  label: "Gender"
                  value: root.person ? root.genderLabel(root.person.gender) : "—"
                }
                FactRow {
                  label: "Place of Birth"
                  value: root.person ? (root.person.place_of_birth || "—") : "—"
                }
              }
            }

            // ---- biography, collapsed to a few lines with a toggle
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.person && root.person.biography
              spacing: 2

              Text {
                text: "Biography"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                id: bioText
                Layout.fillWidth: true
                text: root.person ? (root.person.biography || "") : ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: root.bioExpanded ? 0 : 6
                elide: root.bioExpanded ? Text.ElideNone : Text.ElideRight
              }

              Text {
                visible: bioText.truncated || root.bioExpanded
                text: root.bioExpanded ? "Show less" : "Read More ›"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -4
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.bioExpanded = !root.bioExpanded
                }
              }
            }

            // ---- known for
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.knownFor.length > 0
              spacing: Style.space(5)

              Text {
                text: "Known For"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              ListView {
                id: knownForList
                Layout.fillWidth: true
                // Room for the trailing year line, as with the series cast.
                Layout.preferredHeight: root.cardStrip3
                orientation: ListView.Horizontal
                clip: true
                spacing: Style.space(8)
                model: root.knownFor
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: MediaCard {
                  required property var modelData
                  width: root.cardWidth
                  height: knownForList.height - Style.space(10)
                  path: modelData.poster_path || ""
                  title: modelData.title || modelData.name || ""
                  subtitle: modelData.character || ""
                  extra: root.yearOf(modelData.release_date || modelData.first_air_date)
                  fallbackIcon: root.mediaIcon(modelData.media_type)
                  clickable: true
                  onActivated: root.pushView(modelData.media_type, modelData.id)
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ favorites / watchlist
      ColumnLayout {
        visible: root.view === "favorites" || root.view === "watchlist"
        Layout.fillWidth: true
        spacing: Style.space(8)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          FilterTab {
            filterKey: "movie"
            filterLabel: "Movies"
            active: root.listTab === "movie"
            onPicked: root.listTab = "movie"
          }
          FilterTab {
            filterKey: "tv"
            filterLabel: "TV"
            active: root.listTab === "tv"
            onPicked: root.listTab = "tv"
          }

          Item { Layout.fillWidth: true }

          Text {
            text: root.listsLoading ? "Refreshing…" : root.lastUpdatedText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Refresh"
            foreground: root.fg
            tooltipText: "Refresh from TMDB (r)"
            active: root.listsLoading
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.refreshLists()
          }
        }

        Text {
          visible: root.listsError !== ""
          Layout.fillWidth: true
          text: root.listsError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          visible: !root.connected
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "Connect your TMDB account to see this list"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: root.connected && !root.listsLoaded && !root.listsLoading && root.listsError === ""
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "Press Refresh to load your lists"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: {
            if (!root.connected || !root.listsLoaded || root.listsLoading) return false
            var list = root.view === "favorites" ? root.favorites : root.watchlist
            return list.length === 0
          }
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: root.view === "favorites"
            ? ("No favorite " + (root.listTab === "tv" ? "shows" : "movies"))
            : ("Nothing on your " + (root.listTab === "tv" ? "TV" : "movie") + " watchlist")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ResultRows {
          id: accountRows
          items: root.view === "favorites" ? root.favorites : root.watchlist
          selectable: root.view === "favorites" || root.view === "watchlist"
          visible: root.connected && accountRows.items.length > 0
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(accountRows.contentHeight, Style.space(740))
        }
      }

      // ------------------------------------------------------------ history
      ColumnLayout {
        visible: root.view === "history"
        Layout.fillWidth: true
        spacing: Style.space(8)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Last " + root.historyLimit + " viewed"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            visible: root.history.length > 0
            text: "Clear"
            foreground: root.dim
            tooltipText: "Forget viewing history"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.clearHistory()
          }
        }

        Text {
          visible: root.history.length === 0
          Layout.fillWidth: true
          Layout.topMargin: 8
          horizontalAlignment: Text.AlignHCenter
          text: "Nothing viewed yet"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ResultRows {
          id: historyRows
          items: root.history
          showWhen: true
          selectable: root.view === "history"
          visible: root.history.length > 0
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(historyRows.contentHeight, Style.space(740))
        }
      }

      // ------------------------------------------------------------ footer
      Text {
        Layout.fillWidth: true
        Layout.topMargin: 4
        // Wraps rather than running off the panel: the hint list is longer than
        // one line at the narrower panel widths.
        wrapMode: Text.WordWrap
        lineHeight: 1.25
        text: {
          // Non-breaking space between key and label, so a wrap never splits
          // "v" from "viewed".
          var nb = "\u00a0"
          var keys = ["j/k" + nb + "move", "\u23ce" + nb + "open", "f" + nb + "favorites",
                      "w" + nb + "watchlist", "v" + nb + "viewed", "a" + nb + "account"]
          if (root.view === "favorites" || root.view === "watchlist") keys.unshift("r" + nb + "refresh")
          if (root.view !== "search") keys.unshift("/" + nb + "search")
          keys.push("esc" + nb + (root.navStack.length > 0 ? "back" : "close"))
          return keys.join("  \u00b7  ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
