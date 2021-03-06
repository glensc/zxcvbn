adjacency_graphs = require('./adjacency_graphs')

# on qwerty, 'g' has degree 6, being adjacent to 'ftyhbv'. '\' has degree 1.
# this calculates the average over all keys.
calc_average_degree = (graph) ->
  average = 0
  for key, neighbors of graph
    average += (n for n in neighbors when n).length
  average /= (k for k,v of graph).length
  average

scoring =
  nCk: (n, k) ->
    # http://blog.plover.com/math/choose.html
    return 0 if k > n
    return 1 if k == 0
    r = 1
    for d in [1..k]
      r *= n
      r /= d
      n -= 1
    r

  log10: (n) -> Math.log(n) / Math.log(10) # IE doesn't support Math.log10 :(
  log2:  (n) -> Math.log(n) / Math.log(2)

  factorial: (n) ->
    # unoptimized, called only on small n
    return 1 if n < 2
    f = 1
    f *= i for i in [2..n]
    f

  # ------------------------------------------------------------------------------
  # search --- most guessable match sequence -------------------------------------
  # ------------------------------------------------------------------------------
  #
  # takes a list of overlapping matches, returns the non-overlapping sublist with
  # minimum guesses. O(nm) dp alg for length-n password with m candidate matches.
  #
  # the optimal "minimum guesses" sublist is here defined to be the sublist that
  # minimizes:
  #
  #    product(m.guesses for m in sequence) * factorial(sequence.length)
  #
  # the factorial term is the number of ways to order n patterns. it serves as a
  # light penalty for longer sequences.
  #
  # for example, consider a sequence that is date-repeat-dictionary.
  #  - an attacker would need to try other date-repeat-dictionary combinations,
  #    hence the product term.
  #  - an attacker would need to try repeat-date-dictionary, dictionary-repeat-date,
  #    ..., hence the factorial term.
  #  - an attacker would also likely try length-1 and length-2 sequences before
  #    length-3. those terms tend to be small in comparison and are excluded
  #    for simplicity.
  #
  # ------------------------------------------------------------------------------

  most_guessable_match_sequence: (password, matches) ->
    # at index k, the product of guesses of the optimal sequence covering password[0..k]
    optimal_product = []

    # at index k, the number of matches in the optimal sequence covering password[0..k].
    # used to calculate the factorial term.
    optimal_sequence_length = []

    # if the optimal sequence ends in a bruteforce match, this records those bruteforce
    # characters, otherwise ''
    ending_bruteforce_chars = ''

    # at index k, the final match (match.j == k) in said optimal sequence.
    backpointers = []

    make_bruteforce_match = (i, j) =>
      cardinality = @cardinality password[i..j]
      guesses = Math.pow cardinality, j - i + 1
      # return object:
      pattern: 'bruteforce'
      i: i
      j: j
      token: password[i..j]
      guesses: guesses
      guesses_log10: @log10(guesses)
      cardinality: cardinality
      length: j - i + 1

    for k in [0...password.length]
      # starting scenario to beat:
      # adding a brute-force character to the sequence with min guesses at k-1.
      ending_bruteforce_chars += password.charAt(k)

      l = ending_bruteforce_chars.length
      optimal_product[k] = Math.pow @cardinality(ending_bruteforce_chars), l
      optimal_sequence_length[k] = 1
      if k - l >= 0
        optimal_product[k] *= optimal_product[k - l]
        optimal_sequence_length[k] += optimal_sequence_length[k - l]

      backpointers[k] = make_bruteforce_match(k - l + 1, k)

      minimum_guesses = optimal_product[k] * @factorial optimal_sequence_length[k]
      for match in matches when match.j == k
        [i, j] = [match.i, match.j]
        candidate_product = @estimate_guesses match
        candidate_length = 1
        if i - 1 >= 0
          candidate_product *= optimal_product[i - 1]
          candidate_length += optimal_sequence_length[i - 1]
        candidate_guesses = candidate_product * @factorial candidate_length

        if candidate_guesses < minimum_guesses
          minimum_guesses = candidate_guesses
          ending_bruteforce_chars = ''
          optimal_product[k] = candidate_product
          optimal_sequence_length[k] = candidate_length
          backpointers[k] = match

    # walk backwards and decode the best sequence
    match_sequence = []
    k = password.length - 1
    while k >= 0
      match = backpointers[k]
      match_sequence.push match
      k = match.i - 1
    match_sequence.reverse()

    if password.length > 0
      sequence_length_multiplier = @factorial optimal_sequence_length[password.length - 1]
      guesses = optimal_product[password.length - 1] * sequence_length_multiplier
    else
      sequence_length_multiplier = 1
      guesses = 1

    # final result object
    password: password
    guesses: guesses
    guesses_log10: @log10 guesses
    sequence_product_log10: @log10(optimal_product[password.length - 1])
    sequence_length_multiplier_log10: @log10 sequence_length_multiplier
    sequence: match_sequence

  # ------------------------------------------------------------------------------
  # guess estimation -- one function per match pattern ---------------------------
  # ------------------------------------------------------------------------------

  estimate_guesses: (match) ->
    return match.guesses if match.guesses? # a match's guess estimate doesn't change. cache it.
    estimation_functions =
      dictionary: @dictionary_guesses
      spatial:    @spatial_guesses
      repeat:     @repeat_guesses
      sequence:   @sequence_guesses
      regex:      @regex_guesses
      date:       @date_guesses
    match.guesses = estimation_functions[match.pattern].call this, match
    match.guesses_log10 = @log10 match.guesses
    match.guesses

  repeat_guesses: (match) ->
    match.base_guesses * match.repeat_count

  sequence_guesses: (match) ->
    first_chr = match.token.charAt(0)
    # lower guesses for obvious starting points
    if first_chr in ['a', 'A', 'z', 'Z', '0', '1', '9']
      base_guesses = 4
    else
      if first_chr.match /\d/
        base_guesses = 10 # digits
      else
        # could give a higher base for uppercase,
        # assigning 26 to both upper and lower sequences is more conservative.
        base_guesses = 26
    if not match.ascending
      # need to try a descending sequence in addition to every ascending sequence ->
      # 2x guesses
      base_guesses *= 2
    base_guesses * match.token.length

  MIN_YEAR_SPACE: 20
  REFERENCE_YEAR: 2000
  regex_guesses: (match) ->
    char_class_bases =
      alpha_lower:  26
      alpha_upper:  26
      alpha:        52
      alphanumeric: 62
      digits:       10
      symbols:      33
    if match.regex_name of char_class_bases
      Math.pow(char_class_bases[match.regex_name], match.token.length)
    else switch match.regex_name
      when 'recent_year'
        # conservative estimate of year space: num years from REFERENCE_YEAR.
        # if year is close to REFERENCE_YEAR, estimate a year space of MIN_YEAR_SPACE.
        year_space = Math.abs parseInt(match.regex_match[0]) - @REFERENCE_YEAR
        year_space = Math.max year_space, @MIN_YEAR_SPACE
        year_space

  date_guesses: (match) ->
    # base guesses: (year distance from REFERENCE_YEAR) * num_days * num_years
    year_space = Math.max(Math.abs(match.year - @REFERENCE_YEAR), @MIN_YEAR_SPACE)
    guesses = year_space * 31 * 12
    # double for four-digit years
    guesses *= 2 if match.has_full_year
    # add factor of 4 for separator selection (one of ~4 choices)
    guesses *= 4 if match.separator
    guesses

  KEYBOARD_AVERAGE_DEGREE: calc_average_degree(adjacency_graphs.qwerty)
  # slightly different for keypad/mac keypad, but close enough
  KEYPAD_AVERAGE_DEGREE: calc_average_degree(adjacency_graphs.keypad)

  KEYBOARD_STARTING_POSITIONS: (k for k,v of adjacency_graphs.qwerty).length
  KEYPAD_STARTING_POSITIONS: (k for k,v of adjacency_graphs.keypad).length

  spatial_guesses: (match) ->
    if match.graph in ['qwerty', 'dvorak']
      s = @KEYBOARD_STARTING_POSITIONS
      d = @KEYBOARD_AVERAGE_DEGREE
    else
      s = @KEYPAD_STARTING_POSITIONS
      d = @KEYPAD_AVERAGE_DEGREE
    guesses = 0
    L = match.token.length
    t = match.turns
    # estimate the number of possible patterns w/ length L or less with t turns or less.
    for i in [2..L]
      possible_turns = Math.min(t, i - 1)
      for j in [1..possible_turns]
        guesses += @nCk(i - 1, j - 1) * s * Math.pow(d, j)
    # add extra guesses for shifted keys. (% instead of 5, A instead of a.)
    # math is similar to extra guesses of l33t substitutions in dictionary matches.
    if match.shifted_count
      S = match.shifted_count
      U = match.token.length - match.shifted_count # unshifted count
      if S == 0 or U == 0
        guesses *= 2
      else
        shifted_variations = 0
        shifted_variations += @nCk(S + U, i) for i in [1..Math.min(S, U)]
        guesses *= shifted_variations
    guesses

  dictionary_guesses: (match) ->
    match.base_guesses = match.rank # keep these as properties for display purposes
    match.uppercase_variations = @uppercase_variations match
    match.l33t_variations = @l33t_variations match
    reversed_variations = match.reversed and 2 or 1
    match.base_guesses * match.uppercase_variations * match.l33t_variations * reversed_variations

  START_UPPER: /^[A-Z][^A-Z]+$/
  END_UPPER: /^[^A-Z]+[A-Z]$/
  ALL_UPPER: /^[^a-z]+$/
  ALL_LOWER: /^[^A-Z]+$/

  uppercase_variations: (match) ->
    word = match.token
    return 1 if word.match @ALL_LOWER
    # a capitalized word is the most common capitalization scheme,
    # so it only doubles the search space (uncapitalized + capitalized).
    # allcaps and end-capitalized are common enough too, underestimate as 2x factor to be safe.
    for regex in [@START_UPPER, @END_UPPER, @ALL_UPPER]
      return 2 if word.match regex
    # otherwise calculate the number of ways to capitalize U+L uppercase+lowercase letters
    # with U uppercase letters or less. or, if there's more uppercase than lower (for eg. PASSwORD),
    # the number of ways to lowercase U+L letters with L lowercase letters or less.
    U = (chr for chr in word.split('') when chr.match /[A-Z]/).length
    L = (chr for chr in word.split('') when chr.match /[a-z]/).length
    variations = 0
    variations += @nCk(U + L, i) for i in [1..Math.min(U, L)]
    variations

  l33t_variations: (match) ->
    return 1 if not match.l33t
    variations = 1
    for subbed, unsubbed of match.sub
      # lower-case match.token before calculating: capitalization shouldn't affect l33t calc.
      chrs = match.token.toLowerCase().split('')
      S = (chr for chr in chrs when chr == subbed).length   # num of subbed chars
      U = (chr for chr in chrs when chr == unsubbed).length # num of unsubbed chars
      if S == 0 or U == 0
        # for this sub, password is either fully subbed (444) or fully unsubbed (aaa)
        # treat that as doubling the space (attacker needs to try fully subbed chars in addition to
        # unsubbed.)
        variations *= 2
      else
        # this case is similar to capitalization:
        # with aa44a, U = 3, S = 2, attacker needs to try unsubbed + one sub + two subs
        p = Math.min(U, S)
        possibilities = 0
        possibilities += @nCk(U + S, i) for i in [1..p]
        variations *= possibilities
    variations

  # utilities --------------------------------------------------------------------

  cardinality: (password) ->
    [lower, upper, digits, symbols, latin1_symbols, latin1_letters] = (
      false for i in [0...6]
    )
    unicode_codepoints = []
    for chr in password.split('')
      ord = chr.charCodeAt(0)
      if 0x30 <= ord <= 0x39
        digits = true
      else if 0x41 <= ord <= 0x5a
        upper = true
      else if 0x61 <= ord <= 0x7a
        lower = true
      else if ord <= 0x7f
        symbols = true
      else if 0x80 <= ord <= 0xBF
        latin1_symbols = true
      else if 0xC0 <= ord <= 0xFF
        latin1_letters = true
      else if ord > 0xFF
        unicode_codepoints.push ord
    c = 0
    c += 10 if digits
    c += 26 if upper
    c += 26 if lower
    c += 33 if symbols
    c += 64 if latin1_symbols
    c += 64 if latin1_letters
    if unicode_codepoints.length
      min_cp = max_cp = unicode_codepoints[0]
      for cp in unicode_codepoints[1..]
        min_cp = cp if cp < min_cp
        max_cp = cp if cp > max_cp
      # if the range between unicode codepoints is small,
      # assume one extra alphabet is in use (eg cyrillic, korean) and add a ballpark +40
      #
      # if the range is large, be very conservative and add +100 instead of the range.
      # (codepoint distance between chinese chars can be many thousand, for example,
      # but that cardinality boost won't be justified if the characters are common.)
      range = max_cp - min_cp + 1
      range = 40 if range < 40
      range = 100 if range > 100
      c += range
    c

module.exports = scoring
