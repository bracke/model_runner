with Ada.Unchecked_Deallocation;
with Ada.Wide_Wide_Characters.Handling;

with Model_Runner.UTF8;

package body Model_Runner.Tokenizer.Cutting is

   package Handling renames Ada.Wide_Wide_Characters.Handling;

   ------------------------------------------------------------------------
   --  Character classes
   ------------------------------------------------------------------------

   --  A run of code points, both ends included.
   type Span is record
      First : Natural;
      Last  : Natural;
   end record;

   type Span_Table is array (Positive range <>) of Span;

   --  Whether a code point lies in one of a table's spans, the table being
   --  sorted and its spans disjoint.
   function Within (Code_Point : Natural; Table : Span_Table) return Boolean
   is
      Low  : Natural := Table'First;
      High : Natural := Table'Last;
   begin
      while Low <= High loop
         declare
            Middle : constant Natural := Low + (High - Low) / 2;
         begin
            if Code_Point < Table (Middle).First then
               High := Middle - 1;
            elsif Code_Point > Table (Middle).Last then
               Low := Middle + 1;
            else
               return True;
            end if;
         end;
      end loop;
      return False;
   end Within;

   --  Whether a code point lies in one of a table's spans, the table being
   --  in whatever order the expression wrote it. For the short classes an
   --  expression names outright, where sorting them would be a second copy
   --  of the expression in a different order.
   function Listed (Code_Point : Natural; Table : Span_Table) return Boolean
   is (for some Item of Table =>
         Code_Point in Item.First .. Item.Last);

   --  Unicode punctuation, category P, which the standard library does not
   --  answer for. The two cutting rules that pre-split need exactly the
   --  category and not "everything that is neither letter nor digit": a
   --  currency sign, a degree sign and a multiplication sign are symbols,
   --  and the difference shows in the answer twice. " €5" keeps the space
   --  with the sign and " —b" does not; and WordPiece cuts a word at
   --  punctuation, so "±5" is one word and "a€b" is two.
   --
   --  Ada.Wide_Wide_Characters.Handling answers for letters, digits and
   --  spaces and has no general-category test, so the set is written out.
   --  It is 191 ranges over 842 code points, and it was taken from a
   --  Unicode database rather than from the other runtime: the two agree on
   --  every one of those code points and on no code point outside them,
   --  which is what makes the table evidence rather than a copy.
   Punctuation : constant Span_Table :=
     [(33, 35), (37, 42), (44, 47), (58, 59), (63, 64), (91, 93),
      (95, 95), (123, 123), (125, 125), (161, 161), (167, 167),
      (171, 171), (182, 183), (187, 187), (191, 191), (894, 894),
      (903, 903), (1370, 1375), (1417, 1418), (1470, 1470),
      (1472, 1472), (1475, 1475), (1478, 1478), (1523, 1524),
      (1545, 1546), (1548, 1549), (1563, 1563), (1565, 1567),
      (1642, 1645), (1748, 1748), (1792, 1805), (2039, 2041),
      (2096, 2110), (2142, 2142), (2404, 2405), (2416, 2416),
      (2557, 2557), (2678, 2678), (2800, 2800), (3191, 3191),
      (3204, 3204), (3572, 3572), (3663, 3663), (3674, 3675),
      (3844, 3858), (3860, 3860), (3898, 3901), (3973, 3973),
      (4048, 4052), (4057, 4058), (4170, 4175), (4347, 4347),
      (4960, 4968), (5120, 5120), (5742, 5742), (5787, 5788),
      (5867, 5869), (5941, 5942), (6100, 6102), (6104, 6106),
      (6144, 6154), (6468, 6469), (6686, 6687), (6816, 6822),
      (6824, 6829), (7002, 7008), (7037, 7038), (7164, 7167),
      (7227, 7231), (7294, 7295), (7360, 7367), (7379, 7379),
      (8208, 8231), (8240, 8259), (8261, 8273), (8275, 8286),
      (8317, 8318), (8333, 8334), (8968, 8971), (9001, 9002),
      (10088, 10101), (10181, 10182), (10214, 10223), (10627, 10648),
      (10712, 10715), (10748, 10749), (11513, 11516), (11518, 11519),
      (11632, 11632), (11776, 11822), (11824, 11855), (11858, 11869),
      (12289, 12291), (12296, 12305), (12308, 12319), (12336, 12336),
      (12349, 12349), (12448, 12448), (12539, 12539), (42238, 42239),
      (42509, 42511), (42611, 42611), (42622, 42622), (42738, 42743),
      (43124, 43127), (43214, 43215), (43256, 43258), (43260, 43260),
      (43310, 43311), (43359, 43359), (43457, 43469), (43486, 43487),
      (43612, 43615), (43742, 43743), (43760, 43761), (44011, 44011),
      (64830, 64831), (65040, 65049), (65072, 65106), (65108, 65121),
      (65123, 65123), (65128, 65128), (65130, 65131), (65281, 65283),
      (65285, 65290), (65292, 65295), (65306, 65307), (65311, 65312),
      (65339, 65341), (65343, 65343), (65371, 65371), (65373, 65373),
      (65375, 65381), (65792, 65794), (66463, 66463), (66512, 66512),
      (66927, 66927), (67671, 67671), (67871, 67871), (67903, 67903),
      (68176, 68184), (68223, 68223), (68336, 68342), (68409, 68415),
      (68505, 68508), (69293, 69293), (69461, 69465), (69510, 69513),
      (69703, 69709), (69819, 69820), (69822, 69825), (69952, 69955),
      (70004, 70005), (70085, 70088), (70093, 70093), (70107, 70107),
      (70109, 70111), (70200, 70205), (70313, 70313), (70731, 70735),
      (70746, 70747), (70749, 70749), (70854, 70854), (71105, 71127),
      (71233, 71235), (71264, 71276), (71353, 71353), (71484, 71486),
      (71739, 71739), (72004, 72006), (72162, 72162), (72255, 72262),
      (72346, 72348), (72350, 72354), (72448, 72457), (72769, 72773),
      (72816, 72817), (73463, 73464), (73539, 73551), (73727, 73727),
      (74864, 74868), (77809, 77810), (92782, 92783), (92917, 92917),
      (92983, 92987), (92996, 92996), (93847, 93850), (94178, 94178),
      (113823, 113823), (121479, 121483), (125278, 125279)];

   --  Unicode symbols, category S -- currency, mathematics, modifiers and
   --  the rest -- taken from the same database. Two rules name the class:
   --  DeepSeek V3 cuts a run of punctuation and symbols together, and lets
   --  neither lead a word.
   Symbols : constant Span_Table :=
     [(36, 36), (43, 43), (60, 62), (94, 94), (96, 96), (124, 124),
      (126, 126), (162, 166), (168, 169), (172, 172), (174, 177), (180, 180),
      (184, 184), (215, 215), (247, 247), (706, 709), (722, 735), (741, 747),
      (749, 749), (751, 767), (885, 885), (900, 901), (1014, 1014),
      (1154, 1154), (1421, 1423), (1542, 1544), (1547, 1547), (1550, 1551),
      (1758, 1758), (1769, 1769), (1789, 1790), (2038, 2038), (2046, 2047),
      (2184, 2184), (2546, 2547), (2554, 2555), (2801, 2801), (2928, 2928),
      (3059, 3066), (3199, 3199), (3407, 3407), (3449, 3449), (3647, 3647),
      (3841, 3843), (3859, 3859), (3861, 3863), (3866, 3871), (3892, 3892),
      (3894, 3894), (3896, 3896), (4030, 4037), (4039, 4044), (4046, 4047),
      (4053, 4056), (4254, 4255), (5008, 5017), (5741, 5741), (6107, 6107),
      (6464, 6464), (6622, 6655), (7009, 7018), (7028, 7036), (8125, 8125),
      (8127, 8129), (8141, 8143), (8157, 8159), (8173, 8175), (8189, 8190),
      (8260, 8260), (8274, 8274), (8314, 8316), (8330, 8332), (8352, 8384),
      (8448, 8449), (8451, 8454), (8456, 8457), (8468, 8468), (8470, 8472),
      (8478, 8483), (8485, 8485), (8487, 8487), (8489, 8489), (8494, 8494),
      (8506, 8507), (8512, 8516), (8522, 8525), (8527, 8527), (8586, 8587),
      (8592, 8967), (8972, 9000), (9003, 9254), (9280, 9290), (9372, 9449),
      (9472, 10087), (10132, 10180), (10183, 10213), (10224, 10626),
      (10649, 10711), (10716, 10747), (10750, 11123), (11126, 11157),
      (11159, 11263), (11493, 11498), (11856, 11857), (11904, 11929),
      (11931, 12019), (12032, 12245), (12272, 12283), (12292, 12292),
      (12306, 12307), (12320, 12320), (12342, 12343), (12350, 12351),
      (12443, 12444), (12688, 12689), (12694, 12703), (12736, 12771),
      (12800, 12830), (12842, 12871), (12880, 12880), (12896, 12927),
      (12938, 12976), (12992, 13311), (19904, 19967), (42128, 42182),
      (42752, 42774), (42784, 42785), (42889, 42890), (43048, 43051),
      (43062, 43065), (43639, 43641), (43867, 43867), (43882, 43883),
      (64297, 64297), (64434, 64450), (64832, 64847), (64975, 64975),
      (65020, 65023), (65122, 65122), (65124, 65126), (65129, 65129),
      (65284, 65284), (65291, 65291), (65308, 65310), (65342, 65342),
      (65344, 65344), (65372, 65372), (65374, 65374), (65504, 65510),
      (65512, 65518), (65532, 65533), (65847, 65855), (65913, 65929),
      (65932, 65934), (65936, 65948), (65952, 65952), (66000, 66044),
      (67703, 67704), (68296, 68296), (71487, 71487), (73685, 73713),
      (92988, 92991), (92997, 92997), (113820, 113820), (118608, 118723),
      (118784, 119029), (119040, 119078), (119081, 119140), (119146, 119148),
      (119171, 119172), (119180, 119209), (119214, 119274), (119296, 119361),
      (119365, 119365), (119552, 119638), (120513, 120513), (120539, 120539),
      (120571, 120571), (120597, 120597), (120629, 120629), (120655, 120655),
      (120687, 120687), (120713, 120713), (120745, 120745), (120771, 120771),
      (120832, 121343), (121399, 121402), (121453, 121460), (121462, 121475),
      (121477, 121478), (123215, 123215), (123647, 123647), (126124, 126124),
      (126128, 126128), (126254, 126254), (126704, 126705), (126976, 127019),
      (127024, 127123), (127136, 127150), (127153, 127167), (127169, 127183),
      (127185, 127221), (127245, 127405), (127462, 127490), (127504, 127547),
      (127552, 127560), (127568, 127569), (127584, 127589), (127744, 128727),
      (128732, 128748), (128752, 128764), (128768, 128886), (128891, 128985),
      (128992, 129003), (129008, 129008), (129024, 129035), (129040, 129095),
      (129104, 129113), (129120, 129159), (129168, 129197), (129200, 129201),
      (129280, 129619), (129632, 129645), (129648, 129660), (129664, 129672),
      (129680, 129725), (129727, 129733), (129742, 129755), (129760, 129768),
      (129776, 129784), (129792, 129938), (129940, 129994)];

   --  The numbers that are not decimal digits: letter numbers and other
   --  numbers, categories Nl and No, which the standard library's Is_Digit
   --  leaves out and every expression's \p{N} takes in. A superscript two
   --  and a Roman numeral are numbers to a cutting rule.
   Other_Numbers : constant Span_Table :=
     [(178, 179), (185, 185), (188, 190), (2548, 2553), (2930, 2935),
      (3056, 3058), (3192, 3198), (3416, 3422), (3440, 3448), (3882, 3891),
      (4969, 4988), (5870, 5872), (6128, 6137), (6618, 6618), (8304, 8304),
      (8308, 8313), (8320, 8329), (8528, 8578), (8581, 8585), (9312, 9371),
      (9450, 9471), (10102, 10131), (11517, 11517), (12295, 12295),
      (12321, 12329), (12344, 12346), (12690, 12693), (12832, 12841),
      (12872, 12879), (12881, 12895), (12928, 12937), (12977, 12991),
      (42726, 42735), (43056, 43061), (65799, 65843), (65856, 65912),
      (65930, 65931), (66273, 66299), (66336, 66339), (66369, 66369),
      (66378, 66378), (66513, 66517), (67672, 67679), (67705, 67711),
      (67751, 67759), (67835, 67839), (67862, 67867), (68028, 68029),
      (68032, 68047), (68050, 68095), (68160, 68168), (68221, 68222),
      (68253, 68255), (68331, 68335), (68440, 68447), (68472, 68479),
      (68521, 68527), (68858, 68863), (69216, 69246), (69405, 69414),
      (69457, 69460), (69573, 69579), (69714, 69733), (70113, 70132),
      (71482, 71483), (71914, 71922), (72794, 72812), (73664, 73684),
      (74752, 74862), (93019, 93025), (93824, 93846), (119488, 119507),
      (119520, 119539), (119648, 119672), (125127, 125135), (126065, 126123),
      (126125, 126127), (126129, 126132), (126209, 126253), (126255, 126269),
      (127232, 127244)];

   --  Titlecase letters, category Lt: the digraphs and the Greek letters
   --  with iota subscript that are neither upper nor lower case. The
   --  case-cutting rules put them with the capitals.
   Titlecase : constant Span_Table :=
     [(453, 453), (456, 456), (459, 459), (498, 498), (8072, 8079),
      (8088, 8095), (8104, 8111), (8124, 8124), (8140, 8140), (8188, 8188)];

   --  Enclosing marks, category Me, which the standard library's Is_Mark
   --  leaves out of the marks.
   Enclosing : constant Span_Table :=
     [(1160, 1161), (6846, 6846), (8413, 8416), (8418, 8420), (42608, 42610)];

   --  The letters DeepSeek's first rule names one range at a time -- Latin,
   --  Greek, Cyrillic, Armenian, Georgian, Cherokee and the rest of the
   --  cased scripts, written into its expression rather than asked of a
   --  category. Transcribed from that expression, which is the definition.
   DeepSeek_Letters : constant Span_Table :=
     [(65, 90), (97, 122), (181, 181), (192, 214), (216, 246), (248, 442),
      (444, 447), (452, 659), (661, 687), (880, 883), (886, 886), (887, 887),
      (891, 893), (895, 895), (902, 902), (904, 906), (908, 908), (910, 929),
      (931, 1013), (1015, 1153), (1162, 1327), (1329, 1366), (4256, 4293),
      (5024, 5109), (5112, 5117), (7312, 7354), (7357, 7359), (7424, 7467),
      (7531, 7543), (7545, 7578), (7680, 7957), (7960, 7965), (7968, 8005),
      (8008, 8013), (8016, 8023), (8025, 8025), (8027, 8027), (8029, 8029),
      (8031, 8061), (8064, 8116), (8118, 8124), (8126, 8126), (8130, 8132),
      (8134, 8140), (8144, 8147), (8150, 8155), (8160, 8172), (8178, 8180),
      (8182, 8188), (8450, 8450), (8455, 8455), (8458, 8467), (8469, 8469),
      (8473, 8477), (8484, 8484), (8486, 8486), (8488, 8488), (8490, 8493),
      (8495, 8500), (8505, 8505), (8508, 8511), (8517, 8521), (8526, 8526),
      (8579, 8579), (8580, 8580), (11264, 11387), (11390, 11492),
      (11499, 11502), (11506, 11506), (11507, 11507), (42560, 42605),
      (42624, 42651), (42786, 42863), (42865, 42887), (42891, 42894),
      (43888, 43967), (64256, 64262), (64275, 64279), (65313, 65338),
      (65345, 65370), (66560, 66639), (66736, 66771), (66776, 66811),
      (68736, 68786), (68800, 68850), (71840, 71903), (125184, 125251)];

   --  The punctuation DeepSeek's first rule names: ASCII apart from the
   --  digits and letters, the full-width forms of the same, the quotation
   --  marks, and the ideographic space, comma and full stop.
   DeepSeek_Punctuation : constant Span_Table :=
     [(33, 47), (58, 126), (65281, 65295), (65306, 65374), (8216, 8223),
      (12288, 12290)];

   --  The ideographs DeepSeek's first two rules cut as runs of their own:
   --  the unified ideographs, then a range the expression writes as from
   --  U+0800 to the first ideograph -- which is most of the scripts of Asia
   --  and is what the expression says -- then the Hangul syllables.
   DeepSeek_Ideographs : constant Span_Table :=
     [(2048, 19968), (19968, 40869), (44032, 55295)];

   --  What DeepSeek V3 cuts as runs of its own: the unified ideographs,
   --  hiragana and katakana.
   DeepSeek3_Ideographs : constant Span_Table :=
     [(12352, 12447), (12448, 12543), (19968, 40869)];

   --  What the Han rule of Kimi K2 cuts as runs of its own: the unified
   --  ideographs, their extensions and the compatibility ideographs, as the
   --  other runtime lists them.
   Han : constant Span_Table :=
     [(16#3400#, 16#4DBF#), (16#4E00#, 16#9FFF#), (16#F900#, 16#FAFF#),
      (16#20000#, 16#2A6DF#), (16#2A700#, 16#2B73F#), (16#2B740#, 16#2B81F#),
      (16#2B820#, 16#2CEAF#), (16#2CEB0#, 16#2EBEF#), (16#2F800#, 16#2FA1F#)];

   --  The four classes Youtu cuts as runs of their own, each a run apart
   --  from the others: Hangul, then the full-width and ideographic
   --  punctuation it names, then bopomofo, then the ideographs, hiragana
   --  and katakana.
   Youtu_Hangul : constant Span_Table :=
     [(44032, 55203), (12593, 12686)];
   Youtu_Punctuation : constant Span_Table :=
     [(65281, 65281), (8230, 8230), (8220, 8220), (8221, 8221),
      (8216, 8216), (8217, 8217), (8212, 8212), (65306, 65306),
      (65307, 65307), (65292, 65292), (12289, 12351), (65072, 65103)];
   Youtu_Bopomofo : constant Span_Table :=
     [(12549, 12591)];
   Youtu_Ideographs : constant Span_Table :=
     [(19968, 40869), (12352, 12447), (12448, 12543)];

   --  What AFMoE cuts as runs of its own, as the other runtime's expression
   --  holds it. The third range there is written as from U+8C48 to U+FAFF
   --  -- its first character is a compatibility ideograph that the source
   --  file holds in its decomposed form -- and is transcribed as it stands,
   --  because the expression as it runs is the definition.
   AFMoE_Scripts : constant Span_Table :=
     [(16#4E00#, 16#9FFF#), (16#3400#, 16#4DBF#), (16#8C48#, 16#FAFF#),
      (16#3040#, 16#309F#), (16#30A0#, 16#30FF#), (16#FF65#, 16#FF9F#),
      (16#2F00#, 16#2FDF#), (16#0E40#, 16#0E7F#), (16#0E80#, 16#0EFF#),
      (16#1780#, 16#17FF#), (16#1000#, 16#109F#), (16#AA60#, 16#AA7F#),
      (16#A9E0#, 16#A9FF#), (16#AC00#, 16#D7AF#), (16#1100#, 16#11FF#)];

   --  The characters Bloom's one expression will not put in a word: the
   --  whitespace, and thirteen it lists -- among them the brackets and the
   --  bar the expression's author wrote as grouping and the engine reads as
   --  characters, which is what the expression does and so what this does.
   Bloom_Stops : constant Span_Table :=
     [(40, 41), (124, 124), (46, 46), (44, 44), (33, 33), (63, 63),
      (8230, 8230), (12290, 12290), (65292, 65292), (12289, 12289),
      (2404, 2404), (1748, 1748), (1548, 1548)];

   --  What stands for no code point at all: the position after the last
   --  one, or before the first. Beyond Unicode, so that no positive class
   --  claims it, and named in every negative class so that none of those
   --  does either -- "not a letter" must not be true of the end of a piece.
   None : constant := 16#110000#;

   function Present (Code_Point : Natural) return Boolean
   is (Code_Point < None);

   function Wide (Code_Point : Natural) return Wide_Wide_Character
   is (Wide_Wide_Character'Val (Code_Point));

   function Is_Punctuation (Code_Point : Natural) return Boolean
   is (Within (Code_Point, Punctuation));

   function Is_Symbol (Code_Point : Natural) return Boolean
   is (Within (Code_Point, Symbols));

   function Is_Letter (Code_Point : Natural) return Boolean
   is (Handling.Is_Letter (Wide (Code_Point)));

   --  Every number, \p{N}: the decimal digits and the two categories
   --  beside them.
   function Is_Number (Code_Point : Natural) return Boolean
   is (Handling.Is_Digit (Wide (Code_Point))
       or else Within (Code_Point, Other_Numbers));

   function Is_Mark (Code_Point : Natural) return Boolean
   is (Handling.Is_Mark (Wide (Code_Point))
       or else Within (Code_Point, Enclosing));

   --  Whitespace as the expressions' \s: the ASCII controls that are, and
   --  every space and line terminator Unicode names.
   function Is_Space (Code_Point : Natural) return Boolean
   is (Code_Point in 32 | 9 | 10 | 11 | 12 | 13
       or else Handling.Is_Space (Wide (Code_Point))
       or else Handling.Is_Line_Terminator (Wide (Code_Point)));

   function Is_Line_End (Code_Point : Natural) return Boolean
   is (Code_Point in 10 | 13);

   --  The two halves of a case-cut word. Capitals are the upper- and
   --  titlecase letters; the modifier and other letters and the marks,
   --  which have no case, count on both sides, and that is what makes the
   --  expression's backtracking worth working out rather than assuming.
   function Is_Upperish (Code_Point : Natural) return Boolean
   is ((Is_Letter (Code_Point)
        and then not Handling.Is_Lower (Wide (Code_Point)))
       or else Is_Mark (Code_Point));

   function Is_Lowerish (Code_Point : Natural) return Boolean
   is ((Is_Letter (Code_Point)
        and then not Handling.Is_Upper (Wide (Code_Point))
        and then not Within (Code_Point, Titlecase))
       or else Is_Mark (Code_Point));

   --  Letter or mark, [\p{L}\p{M}].
   function Is_Letter_Or_Mark (Code_Point : Natural) return Boolean
   is (Is_Letter (Code_Point) or else Is_Mark (Code_Point));

   --  What may lead a word under the later rules: anything but a line end,
   --  a letter or a number.
   function May_Lead (Code_Point : Natural) return Boolean
   is (Present (Code_Point)
       and then not Is_Line_End (Code_Point)
       and then not Is_Letter (Code_Point)
       and then not Is_Number (Code_Point));

   --  What a symbol run is made of under most rules: neither whitespace,
   --  letter nor number.
   function Is_Other (Code_Point : Natural) return Boolean
   is (Present (Code_Point)
       and then not Is_Space (Code_Point)
       and then not Is_Letter (Code_Point)
       and then not Is_Number (Code_Point));

   function Is_ASCII_Digit (Code_Point : Natural) return Boolean
   is (Code_Point in 48 .. 57);

   function Is_ASCII_Letter (Code_Point : Natural) return Boolean
   is (Code_Point in 65 .. 90 | 97 .. 122);

   --  ASCII apart from the letters, digits, space and controls, which is
   --  what DeepSeek V3 lets lead a Latin word and what Chameleon cuts one
   --  at a time.
   function Is_ASCII_Punctuation (Code_Point : Natural) return Boolean
   is (Code_Point in 33 .. 47 | 58 .. 64 | 91 .. 96 | 123 .. 126);

   ------------------------------------------------------------------------
   --  What a rule is made of
   ------------------------------------------------------------------------

   --  The alternatives of a rule's main expression, each in one of the
   --  shapes the rules use, and No_ where a rule has no such alternative.
   --  The alternation is always in this order -- a contraction, a word, a
   --  run of numbers, a run of symbols, whitespace -- because every
   --  expression the rules use writes it so.

   type Contraction_Kind is (No_Contraction, As_Written, Any_Case);

   --  How a word is found. Space_Led is the original rule's " ?\p{L}+";
   --  Any_Led lets any character that is neither line end, letter nor
   --  number lead; Marks_Kept is that with combining marks in the word;
   --  Cased cuts at a change of case; DeepSeek3 is its two alternatives,
   --  a Latin word led by ASCII punctuation and a word led by anything
   --  but a line end, a letter, punctuation or a symbol; Spaced lets a
   --  single space between two letters continue the word; Bloom takes a
   --  run of anything but whitespace and the thirteen stops.
   type Word_Kind is
     (No_Word, Space_Led, Any_Led, Marks_Kept, Cased, DeepSeek3, Spaced,
      Bloom);

   --  How numbers are taken: with a space allowed to lead a run, one at a
   --  time, in threes, or as a whole run with nothing leading it.
   type Number_Kind is (No_Numbers, Space_Led_Run, One, Threes, Run);

   --  A run of symbols, " ?[^\s\p{L}\p{N}]+", and what may trail it:
   --  nothing, line ends, line ends and slashes, or at most one of those.
   --  Marks_Kept leaves combining marks to the word, as qwen35 does;
   --  Punctuation_And_Symbols takes only those two categories, as DeepSeek
   --  V3 does.
   type Symbol_Kind is
     (No_Symbols, Plain, Line_Ends, Line_Ends_And_Slashes,
      One_Line_End_Or_Slash, Marks_Kept, Punctuation_And_Symbols);

   --  How whitespace is taken. The original rule has "\s+(?!\S)" alone --
   --  a lone space before a word is left for nothing, and becomes a piece
   --  of its own between matches; the later rules put "\s*[\r\n]+" before
   --  it and "\s+" after; Jais 2 replaces the middle with a cascade of
   --  fixed widths.
   type Space_Kind is (No_Spaces, Original_Spaces, Later, Cascade);

   type Alternation is record
      Contraction : Contraction_Kind := No_Contraction;
      --  Whether a word may carry a contraction after it, in any case.
      Suffix      : Boolean := False;
      Word        : Word_Kind := No_Word;
      Numbers     : Number_Kind := No_Numbers;
      Symbols     : Symbol_Kind := No_Symbols;
      Spaces      : Space_Kind := No_Spaces;
   end record;

   --  One pass over the pieces, which is one expression of the other
   --  runtime's list.
   type Pass_Kind is
     (Main,                  --  The alternation above.
      Each_Line_End,         --  [\r\n]
      Lines_Or_Line_Ends,    --  [^\n]+|[\n]+
      Number_Runs,           --  \p{N}+
      Each_Number,           --  \p{N}
      Threes_From_Left,      --  \p{N}{1,3}, or [0-9][0-9][0-9]
      Threes_From_Right,     --  digits grouped from the right
      Threes_Boundaries,     --  (?=(\d{3})+(?!\d)): boundaries alone
      Class_Runs,            --  runs of one table's characters
      Punctuation_Runs,      --  [\p{P}\$\+<=>\^~\|]+, with or without `
      Trailing_Spaces,       --  \s+$
      Space_Led_Letters,     --  \s?\p{L}+
      Space_Led_Punctuation, --  \s?\p{P}+
      DeepSeek_Words,        --  \s?[the letter ranges]+
      DeepSeek_Stops,        --  \s?[the punctuation ranges]+
      Chameleon_Spaces,      --  ([\t\n]|    |  )
      Chameleon_Stops,       --  [\p{P}!-/:-@\[-`{-~]
      Chameleon_Sentinels,   --  <sentinel:[0-9]+>
      Chameleon_Images);     --  (IMGIMG)((A|B|C|D|E|F|G|H|I){1,4})Z

   --  Which table a Class_Runs pass reads.
   type Class_Table is
     (DeepSeek_Table, DeepSeek3_Table, Han_Table, Youtu_Table, AFMoE_Table);

   type Pass is record
      Kind       : Pass_Kind := Main;
      Rule       : Alternation;
      Table      : Class_Table := Han_Table;
      --  Threes: whether only the ASCII digits count, which is what an
      --  expression written with [0-9] or \d asks and \p{N} does not.
      ASCII_Only : Boolean := False;
      --  Punctuation_Runs: whether the grave accent is in the class, which
      --  is the whole difference between falcon's and the default's.
      Grave      : Boolean := False;
   end record;

   type Pass_List is array (Positive range <>) of Pass;

   --  The main expressions the rules share.

   --  The original rule's, which gpt-2 carries whole and the default,
   --  falcon, smollm and chameleon run after a pass of their own.
   Original : constant Alternation :=
     (Contraction => As_Written, Suffix => False, Word => Space_Led,
      Numbers => Space_Led_Run, Symbols => Plain, Spaces => Original_Spaces);

   --  Llama 3's: any character may lead a word, digits in threes.
   Llama3 : constant Alternation :=
     (Contraction => Any_Case, Suffix => False, Word => Any_Led,
      Numbers => Threes, Symbols => Line_Ends, Spaces => Later);

   --  Qwen 2's: Llama 3's with digits one at a time.
   Qwen2 : constant Alternation :=
     (Contraction => Any_Case, Suffix => False, Word => Any_Led,
      Numbers => One, Symbols => Line_Ends, Spaces => Later);

   --  Tekken's: a word is cut where its case changes, digits one at a
   --  time, a slash may trail a symbol run.
   Tekken : constant Alternation :=
     (Contraction => No_Contraction, Suffix => False, Word => Cased,
      Numbers => One, Symbols => Line_Ends_And_Slashes, Spaces => Later);

   --  GPT-4o's: Tekken's with a contraction allowed after a word and
   --  digits in threes.
   GPT4o : constant Alternation :=
     (Contraction => No_Contraction, Suffix => True, Word => Cased,
      Numbers => Threes, Symbols => Line_Ends_And_Slashes, Spaces => Later);

   --  DeepSeek V3's, which runs after its digits and ideographs are cut
   --  out, so it names no numbers.
   DeepSeek3_Words : constant Alternation :=
     (Contraction => No_Contraction, Suffix => False, Word => DeepSeek3,
      Numbers => No_Numbers, Symbols => Punctuation_And_Symbols,
      Spaces => Later);

   --  Bloom's, which is one alternative and nothing else.
   Bloom_Words : constant Alternation :=
     (Contraction => No_Contraction, Suffix => False, Word => Bloom,
      Numbers => No_Numbers, Symbols => No_Symbols, Spaces => No_Spaces);

   --  The passes each rule runs, in order, transcribed from the other
   --  runtime's expression lists.
   function Passes (Rule : Cut_Rule) return Pass_List is
   begin
      case Rule is
         when Rule_Default =>
            return [(Kind => Punctuation_Runs, Grave => False, others => <>),
                    (Kind => Main, Rule => Original, others => <>),
                    (Kind => Number_Runs, others => <>),
                    (Kind => Threes_From_Left, ASCII_Only => True,
                     others => <>)];
         when Rule_GPT2 =>
            return [(Kind => Main, Rule => Original, others => <>)];
         when Rule_Falcon =>
            return [(Kind => Punctuation_Runs, Grave => True, others => <>),
                    (Kind => Main, Rule => Original, others => <>),
                    (Kind => Threes_From_Left, ASCII_Only => True,
                     others => <>)];
         when Rule_SmolLM =>
            return [(Kind => Each_Number, others => <>),
                    (Kind => Main, Rule => Original, others => <>)];
         when Rule_Llama3 =>
            return [(Kind => Main, Rule => Llama3, others => <>)];
         when Rule_MiniCPM5 =>
            return [(Kind => Threes_From_Left, ASCII_Only => False,
                     others => <>),
                    (Kind => Main,
                     Rule => (Llama3 with delta Numbers => Run),
                     others => <>)];
         when Rule_Jais2 =>
            return [(Kind => Main,
                     Rule => (Llama3 with delta Spaces => Cascade),
                     others => <>)];
         when Rule_Qwen2 =>
            return [(Kind => Main, Rule => Qwen2, others => <>)];
         when Rule_Qwen35 =>
            return [(Kind => Main,
                     Rule => (Qwen2 with delta Word => Marks_Kept,
                                             Symbols => Marks_Kept),
                     others => <>)];
         when Rule_Bailing =>
            --  "\s*[\r\n]" where Qwen 2 has "\s*[\r\n]+": the same cut,
            --  because the whitespace before the last line end is what
            --  the star takes either way.
            return [(Kind => Main, Rule => Qwen2, others => <>)];
         when Rule_Seed_Coder =>
            return [(Kind => Main,
                     Rule => (Qwen2 with delta Symbols => Plain),
                     others => <>)];
         when Rule_Laguna =>
            return [(Kind => Lines_Or_Line_Ends, others => <>),
                    (Kind => Main, Rule => Qwen2, others => <>)];
         when Rule_ExaOne_MoE =>
            return [(Kind => Main,
                     Rule => (Qwen2 with delta Word => Spaced,
                                             Symbols => One_Line_End_Or_Slash),
                     others => <>)];
         when Rule_Tekken =>
            return [(Kind => Main, Rule => Tekken, others => <>)];
         when Rule_GPT4o =>
            return [(Kind => Main, Rule => GPT4o, others => <>)];
         when Rule_Tiny_Aya =>
            return [(Kind => Threes_From_Right, ASCII_Only => True,
                     others => <>),
                    (Kind => Main, Rule => GPT4o, others => <>)];
         when Rule_Youtu =>
            return [(Kind => Class_Runs, Table => Youtu_Table, others => <>),
                    (Kind => Main,
                     Rule => (GPT4o with delta Numbers => One),
                     others => <>)];
         when Rule_Kimi_K2 =>
            --  GPT-4o's expression after the Han runs are cut out, with
            --  nothing but line ends trailing a symbol run. The other
            --  runtime's hand-written cutter for this rule does not cut a
            --  word at its case; the model's own expression does, and it
            --  is the model's own that is transcribed here.
            return [(Kind => Class_Runs, Table => Han_Table, others => <>),
                    (Kind => Main,
                     Rule => (GPT4o with delta Symbols => Line_Ends),
                     others => <>)];
         when Rule_DeepSeek_LLM =>
            return [(Kind => Each_Line_End, others => <>),
                    (Kind => DeepSeek_Words, others => <>),
                    (Kind => DeepSeek_Stops, others => <>),
                    (Kind => Trailing_Spaces, others => <>),
                    (Kind => Class_Runs, Table => DeepSeek_Table,
                     others => <>),
                    (Kind => Number_Runs, others => <>)];
         when Rule_DeepSeek_Coder =>
            return [(Kind => Each_Line_End, others => <>),
                    (Kind => Space_Led_Letters, others => <>),
                    (Kind => Space_Led_Punctuation, others => <>),
                    (Kind => Class_Runs, Table => DeepSeek_Table,
                     others => <>),
                    (Kind => Each_Number, others => <>)];
         when Rule_DeepSeek3 =>
            return [(Kind => Threes_From_Left, ASCII_Only => False,
                     others => <>),
                    (Kind => Class_Runs, Table => DeepSeek3_Table,
                     others => <>),
                    (Kind => Main, Rule => DeepSeek3_Words, others => <>)];
         when Rule_AFMoE =>
            return [(Kind => Threes_From_Right, ASCII_Only => False,
                     others => <>),
                    (Kind => Class_Runs, Table => AFMoE_Table, others => <>),
                    (Kind => Main, Rule => DeepSeek3_Words, others => <>)];
         when Rule_Bloom =>
            return [(Kind => Main, Rule => Bloom_Words, others => <>)];
         when Rule_Viking =>
            return [(Kind => Main, Rule => Bloom_Words, others => <>),
                    (Kind => Each_Number, others => <>)];
         when Rule_SuperBPE =>
            --  Nothing is cut but the digits, and those by an expression
            --  that matches nothing at all: a boundary wherever a run of
            --  ASCII digits that is a multiple of three long begins. Not
            --  the same as taking the groups, though it reads so: a piece
            --  the first pass made out of ASCII digits and other numbers
            --  keeps its other numbers on the last group, where a group
            --  taken as a match would leave them a piece of their own.
            return [(Kind => Number_Runs, others => <>),
                    (Kind => Threes_Boundaries, others => <>)];
         when Rule_Chameleon =>
            return [(Kind => Chameleon_Sentinels, others => <>),
                    (Kind => Chameleon_Images, others => <>),
                    (Kind => Chameleon_Spaces, others => <>),
                    (Kind => Each_Number, others => <>),
                    (Kind => Chameleon_Stops, others => <>),
                    (Kind => Main, Rule => Original, others => <>)];
      end case;
   end Passes;

   ------------------------------------------------------------------------
   --  Cutting
   ------------------------------------------------------------------------

   type Point_Array is array (Positive range <>) of Natural;
   type Point_Array_Access is access Point_Array;

   procedure Free_Points is
     new Ada.Unchecked_Deallocation (Point_Array, Point_Array_Access);

   procedure Free_Ends is
     new Ada.Unchecked_Deallocation (Piece_Ends, Piece_Ends_Access);

   procedure Free (Item : in out Piece_Ends_Access) is
   begin
      Free_Ends (Item);
   end Free;

   procedure Cut
     (Text  : String;
      Rule  : Cut_Rule;
      Ends  : out Piece_Ends_Access;
      Count : out Natural)
   is
      --  The text as code points, and where each begins in the text. One
      --  more start than there are points, so that the byte after the
      --  last point has a name.
      Points : Point_Array_Access := new Point_Array (1 .. Text'Length);
      Starts : Point_Array_Access := new Point_Array (1 .. Text'Length + 1);
      Total  : Natural := 0;

      --  The pieces so far and the pieces a pass is making, as the index
      --  of each piece's last code point. Two arrays, swapped after each
      --  pass; a pass never makes fewer pieces than it was given.
      Before : Point_Array_Access := new Point_Array (1 .. Text'Length);
      After  : Point_Array_Access := new Point_Array (1 .. Text'Length);
      Held   : Natural := 0;
      Made   : Natural := 0;

      --  The piece a pass is cutting.
      Lo, Hi : Natural := 0;

      function At_Point (Index : Natural) return Natural
      is (if Index in Lo .. Hi then Points (Index) else None);

      --  The last of a run of code points from From that satisfy Test, or
      --  From - 1 when From does not.
      generic
         with function Test (Code_Point : Natural) return Boolean;
      function Run_End (From : Natural) return Natural;

      function Run_End (From : Natural) return Natural is
         Index : Natural := From;
      begin
         while Index <= Hi and then Test (Points (Index)) loop
            Index := Index + 1;
         end loop;
         return Index - 1;
      end Run_End;

      function Letters_End is new Run_End (Is_Letter);
      function Numbers_End is new Run_End (Is_Number);
      function Spaces_End is new Run_End (Is_Space);
      function Others_End is new Run_End (Is_Other);
      function Letters_Or_Marks_End is new Run_End (Is_Letter_Or_Mark);
      function Upperish_End is new Run_End (Is_Upperish);
      function Lowerish_End is new Run_End (Is_Lowerish);
      function ASCII_Digits_End is new Run_End (Is_ASCII_Digit);
      function ASCII_Letters_End is new Run_End (Is_ASCII_Letter);

      --  Where a contraction beginning at From ends, or 0. The seven the
      --  original rule named, in the order it named them; the later rules
      --  take them in any case.
      function Contraction_End
        (From : Natural; Kind : Contraction_Kind) return Natural
      is
         function Letter (Index : Natural; Wanted : Character)
           return Boolean
         is
            Value : constant Natural := At_Point (Index);
         begin
            return Value = Character'Pos (Wanted)
              or else (Kind = Any_Case
                       and then Value = Character'Pos (Wanted) - 32);
         end Letter;
      begin
         if Kind = No_Contraction or else At_Point (From) /= 39 then
            return 0;
         end if;

         if Letter (From + 1, 's') or else Letter (From + 1, 't')
           or else Letter (From + 1, 'm') or else Letter (From + 1, 'd')
         then
            return From + 1;
         end if;

         if (Letter (From + 1, 'r') and then Letter (From + 2, 'e'))
           or else (Letter (From + 1, 'v') and then Letter (From + 2, 'e'))
           or else (Letter (From + 1, 'l') and then Letter (From + 2, 'l'))
         then
            return From + 2;
         end if;

         return 0;
      end Contraction_End;

      --  Where a case-cut word beginning at From ends, or 0. The
      --  expression is two alternatives, "U*l+" and "U+l*", with U the
      --  upperish class and l the lowerish one, and the two classes
      --  overlap in every letter without case. Greedy with backtracking,
      --  the first is: take the longest upperish prefix, then step it back
      --  until the code point after it is lowerish and take the lowerish
      --  run from there. The second is the upperish prefix and whatever
      --  lowerish run follows it, which may be none.
      function Cased_First_End (From : Natural) return Natural is
         Capitals : constant Natural := Upperish_End (From);
      begin
         for Prefix in reverse From - 1 .. Capitals loop
            if Is_Lowerish (At_Point (Prefix + 1)) then
               return Lowerish_End (Prefix + 1);
            end if;
         end loop;
         return 0;
      end Cased_First_End;

      function Cased_Second_End (From : Natural) return Natural is
         Capitals : constant Natural := Upperish_End (From);
      begin
         return (if Capitals >= From then Lowerish_End (Capitals + 1) else 0);
      end Cased_Second_End;

      --  Where a word beginning at From ends under Kind, or 0. The
      --  optional leading character is tried first and given back when
      --  nothing follows it, which is what the expression's "?" does.
      function Word_End (From : Natural; Kind : Word_Kind) return Natural is
         Here : constant Natural := At_Point (From);
      begin
         case Kind is
            when No_Word =>
               return 0;

            when Space_Led =>
               if Here = 32 and then Is_Letter (At_Point (From + 1)) then
                  return Letters_End (From + 1);
               elsif Is_Letter (Here) then
                  return Letters_End (From);
               end if;
               return 0;

            when Any_Led =>
               if May_Lead (Here) and then Is_Letter (At_Point (From + 1))
               then
                  return Letters_End (From + 1);
               elsif Is_Letter (Here) then
                  return Letters_End (From);
               end if;
               return 0;

            when Marks_Kept =>
               if May_Lead (Here)
                 and then Is_Letter_Or_Mark (At_Point (From + 1))
               then
                  return Letters_Or_Marks_End (From + 1);
               elsif Is_Letter_Or_Mark (Here) then
                  return Letters_Or_Marks_End (From);
               end if;
               return 0;

            when Cased =>
               --  Two alternatives, each with its own optional lead, in
               --  the expression's order: the first with the lead taken,
               --  the first without, the second with, the second without.
               --  The order shows on a mark before capitals, which may
               --  lead and is lowerish at once.
               declare
                  Stop : Natural;
               begin
                  if May_Lead (Here) then
                     Stop := Cased_First_End (From + 1);
                     if Stop > 0 then
                        return Stop;
                     end if;
                  end if;
                  Stop := Cased_First_End (From);
                  if Stop > 0 then
                     return Stop;
                  end if;
                  if May_Lead (Here) then
                     Stop := Cased_Second_End (From + 1);
                     if Stop > 0 then
                        return Stop;
                     end if;
                  end if;
                  return Cased_Second_End (From);
               end;

            when DeepSeek3 =>
               --  A Latin word led by ASCII punctuation first, then a word
               --  of letters and marks led by anything that is not a line
               --  end, a letter, punctuation or a symbol.
               if Is_ASCII_Punctuation (Here)
                 and then Is_ASCII_Letter (At_Point (From + 1))
               then
                  return ASCII_Letters_End (From + 1);
               end if;

               if Present (Here)
                 and then not Is_Line_End (Here) and then not Is_Letter (Here)
                 and then not Is_Punctuation (Here)
                 and then not Is_Symbol (Here)
                 and then Is_Letter_Or_Mark (At_Point (From + 1))
               then
                  return Letters_Or_Marks_End (From + 1);
               elsif Is_Letter_Or_Mark (Here) then
                  return Letters_Or_Marks_End (From);
               end if;
               return 0;

            when Spaced =>
               --  A letter and its marks, and then as many more as follow,
               --  a single space between two letters allowed.
               declare
                  function Body_End (Start : Natural) return Natural is
                     Index : Natural := Start;
                  begin
                     if not Is_Letter (At_Point (Index)) then
                        return 0;
                     end if;
                     loop
                        Index := Index + 1;
                        while Is_Mark (At_Point (Index)) loop
                           Index := Index + 1;
                        end loop;
                        if Is_Letter (At_Point (Index)) then
                           null;
                        elsif At_Point (Index) = 32
                          and then Is_Letter (At_Point (Index + 1))
                        then
                           Index := Index + 1;
                        else
                           return Index - 1;
                        end if;
                     end loop;
                  end Body_End;
               begin
                  if May_Lead (Here) then
                     declare
                        Led : constant Natural := Body_End (From + 1);
                     begin
                        if Led > 0 then
                           return Led;
                        end if;
                     end;
                  end if;
                  return Body_End (From);
               end;

            when Bloom =>
               declare
                  function Allowed (Code_Point : Natural) return Boolean
                  is (Present (Code_Point)
                      and then not Is_Space (Code_Point)
                      and then not Listed (Code_Point, Bloom_Stops));
                  function Allowed_End is new Run_End (Allowed);
               begin
                  if Here = 32 and then Allowed (At_Point (From + 1)) then
                     return Allowed_End (From + 1);
                  elsif Allowed (Here) then
                     return Allowed_End (From);
                  end if;
                  return 0;
               end;
         end case;
      end Word_End;

      --  Where a run of numbers beginning at From ends under Kind, or 0.
      function Numbers_End (From : Natural; Kind : Number_Kind)
        return Natural
      is
         Here : constant Natural := At_Point (From);
      begin
         case Kind is
            when No_Numbers =>
               return 0;
            when Space_Led_Run =>
               if Here = 32 and then Is_Number (At_Point (From + 1)) then
                  return Numbers_End (From + 1);
               elsif Is_Number (Here) then
                  return Numbers_End (From);
               end if;
               return 0;
            when One =>
               return (if Is_Number (Here) then From else 0);
            when Threes =>
               if not Is_Number (Here) then
                  return 0;
               end if;
               return Natural'Min (Numbers_End (From), From + 2);
            when Run =>
               return (if Is_Number (Here) then Numbers_End (From) else 0);
         end case;
      end Numbers_End;

      --  Where a run of symbols beginning at From ends under Kind, or 0.
      function Symbols_End (From : Natural; Kind : Symbol_Kind)
        return Natural
      is
         function Kept_Mark (Code_Point : Natural) return Boolean
         is (Is_Other (Code_Point) and then not Is_Mark (Code_Point));
         function Kept_Marks_End is new Run_End (Kept_Mark);

         function Stop_Or_Symbol (Code_Point : Natural) return Boolean
         is (Is_Punctuation (Code_Point) or else Is_Symbol (Code_Point));
         function Stops_Or_Symbols_End is new Run_End (Stop_Or_Symbol);

         function Member (Code_Point : Natural) return Boolean
         is (case Kind is
                when Marks_Kept => Kept_Mark (Code_Point),
                when Punctuation_And_Symbols => Stop_Or_Symbol (Code_Point),
                when others => Is_Other (Code_Point));

         function Member_End (Start : Natural) return Natural
         is (case Kind is
                when Marks_Kept => Kept_Marks_End (Start),
                when Punctuation_And_Symbols => Stops_Or_Symbols_End (Start),
                when others => Others_End (Start));

         Here : constant Natural := At_Point (From);
         Stop : Natural;
      begin
         if Kind = No_Symbols then
            return 0;
         end if;

         if Here = 32 and then Member (At_Point (From + 1)) then
            Stop := Member_End (From + 1);
         elsif Member (Here) then
            Stop := Member_End (From);
         else
            return 0;
         end if;

         --  What may trail the run.
         case Kind is
            when Line_Ends | Marks_Kept | Punctuation_And_Symbols =>
               while Is_Line_End (At_Point (Stop + 1)) loop
                  Stop := Stop + 1;
               end loop;
            when Line_Ends_And_Slashes =>
               while Is_Line_End (At_Point (Stop + 1))
                 or else At_Point (Stop + 1) = 47
               loop
                  Stop := Stop + 1;
               end loop;
            when One_Line_End_Or_Slash =>
               if Is_Line_End (At_Point (Stop + 1))
                 or else At_Point (Stop + 1) = 47
               then
                  Stop := Stop + 1;
               end if;
            when others =>
               null;
         end case;

         return Stop;
      end Symbols_End;

      --  Where a run of whitespace beginning at From ends under Kind, or
      --  0. "\s+(?!\S)" takes the whole run when nothing follows it and
      --  all but its last character otherwise, which leaves that character
      --  for the word after; a run of one before a word is left for
      --  nothing, and is taken by "\s+" where the rule has it.
      function Spaces_End (From : Natural; Kind : Space_Kind)
        return Natural
      is
         Stop : constant Natural := Spaces_End (From);
         Last_Line_End : Natural := 0;
      begin
         if Kind = No_Spaces or else Stop < From then
            return 0;
         end if;

         --  "\s*[\r\n]+": the run up to its last line end.
         if Kind in Later | Cascade then
            for Index in reverse From .. Stop loop
               if Is_Line_End (Points (Index)) then
                  Last_Line_End := Index;
                  exit;
               end if;
            end loop;
            if Last_Line_End > 0 then
               return Last_Line_End;
            end if;
         end if;

         if Kind = Cascade then
            --  "\s{512}(?!\S)|\s{256}(?!\S)|...|\s{1,2}(?!\S)|\s{1}": a
            --  width matches when the run is longer than it, or exactly
            --  it with nothing after.
            declare
               Length : constant Natural := Stop - From + 1;
               Widths : constant array (1 .. 10) of Positive :=
                 [512, 256, 128, 64, 32, 16, 8, 4, 2, 1];
            begin
               for Width of Widths loop
                  if Length > Width
                    or else (Length = Width and then Stop = Hi)
                  then
                     return From + Width - 1;
                  end if;
               end loop;
               return From;
            end;
         end if;

         if Stop = Hi then
            return Stop;
         elsif Stop > From then
            return Stop - 1;
         elsif Kind = Later then
            return From;
         end if;

         return 0;
      end Spaces_End;

      --  Where the main expression's match beginning at From ends, or 0:
      --  the alternatives in their order, the first that matches taken.
      function Main_End (From : Natural; Rule : Alternation) return Natural
      is
         Stop : Natural;
      begin
         Stop := Contraction_End (From, Rule.Contraction);
         if Stop > 0 then
            return Stop;
         end if;

         Stop := Word_End (From, Rule.Word);
         if Stop > 0 then
            if Rule.Suffix then
               declare
                  Suffix : constant Natural :=
                    Contraction_End (Stop + 1, Any_Case);
               begin
                  if Suffix > 0 then
                     return Suffix;
                  end if;
               end;
            end if;
            return Stop;
         end if;

         Stop := Numbers_End (From, Rule.Numbers);
         if Stop > 0 then
            return Stop;
         end if;

         Stop := Symbols_End (From, Rule.Symbols);
         if Stop > 0 then
            return Stop;
         end if;

         return Spaces_End (From, Rule.Spaces);
      end Main_End;

      --  What Match_End answers for an expression that matches nothing
      --  and draws a boundary before From.
      Boundary : constant Natural := Natural'Last;

      --  Where a match of Step beginning at From ends, or 0 for none, or
      --  Boundary.
      function Match_End (From : Natural; Step : Pass) return Natural is
         Here : constant Natural := At_Point (From);
      begin
         case Step.Kind is
            when Main =>
               return Main_End (From, Step.Rule);

            when Each_Line_End =>
               return (if Is_Line_End (Here) then From else 0);

            when Lines_Or_Line_Ends =>
               declare
                  function Not_Line_Feed (Code_Point : Natural)
                    return Boolean is (Code_Point /= 10);
                  function Line_Feed (Code_Point : Natural)
                    return Boolean is (Code_Point = 10);
                  function Line_End is new Run_End (Not_Line_Feed);
                  function Feeds_End is new Run_End (Line_Feed);
               begin
                  return (if Here = 10 then Feeds_End (From)
                          else Line_End (From));
               end;

            when Number_Runs =>
               return (if Is_Number (Here) then Numbers_End (From) else 0);

            when Each_Number =>
               return (if Is_Number (Here) then From else 0);

            when Threes_From_Left =>
               if Step.ASCII_Only then
                  --  "[0-9][0-9][0-9]": exactly three, or nothing.
                  if Is_ASCII_Digit (Here)
                    and then Is_ASCII_Digit (At_Point (From + 1))
                    and then Is_ASCII_Digit (At_Point (From + 2))
                  then
                     return From + 2;
                  end if;
                  return 0;
               end if;
               return Numbers_End (From, Threes);

            when Threes_From_Right =>
               --  A run of digits cut so that every group but the first
               --  has three; the first has what is left over.
               declare
                  Stop : constant Natural :=
                    (if Step.ASCII_Only then ASCII_Digits_End (From)
                     else Numbers_End (From));
                  Remainder : Natural;
               begin
                  if Stop < From then
                     return 0;
                  end if;
                  Remainder := (Stop - From + 1) mod 3;
                  return (if Remainder > 0 then From + Remainder - 1
                          else From + 2);
               end;

            when Threes_Boundaries =>
               declare
                  Stop : constant Natural := ASCII_Digits_End (From);
               begin
                  return (if Stop >= From + 2
                            and then (Stop - From + 1) mod 3 = 0
                          then Boundary else 0);
               end;

            when Class_Runs =>
               declare
                  function In_Table
                    (Code_Point : Natural; Table : Span_Table)
                     return Boolean
                  is (Listed (Code_Point, Table));

                  --  A run of one table's characters, from From.
                  function Table_End (Table : Span_Table) return Natural is
                     Index : Natural := From;
                  begin
                     while Index <= Hi
                       and then In_Table (Points (Index), Table)
                     loop
                        Index := Index + 1;
                     end loop;
                     return Index - 1;
                  end Table_End;

                  Stop : Natural := From - 1;
               begin
                  case Step.Table is
                     when DeepSeek_Table =>
                        Stop := Table_End (DeepSeek_Ideographs);
                     when DeepSeek3_Table =>
                        Stop := Table_End (DeepSeek3_Ideographs);
                     when Han_Table =>
                        Stop := Table_End (Han);
                     when AFMoE_Table =>
                        Stop := Table_End (AFMoE_Scripts);
                     when Youtu_Table =>
                        --  Four alternatives, each a run of its own
                        --  class, in the expression's order.
                        if In_Table (Here, Youtu_Hangul) then
                           Stop := Table_End (Youtu_Hangul);
                        elsif In_Table (Here, Youtu_Punctuation) then
                           Stop := Table_End (Youtu_Punctuation);
                        elsif In_Table (Here, Youtu_Bopomofo) then
                           Stop := Table_End (Youtu_Bopomofo);
                        elsif In_Table (Here, Youtu_Ideographs) then
                           Stop := Table_End (Youtu_Ideographs);
                        end if;
                  end case;
                  return (if Stop >= From then Stop else 0);
               end;

            when Punctuation_Runs =>
               declare
                  function Cut_Whole (Code_Point : Natural) return Boolean
                  is (Code_Point in 36 | 43 | 60 | 61 | 62 | 94 | 124 | 126
                      or else (Step.Grave and then Code_Point = 96)
                      or else Is_Punctuation (Code_Point));
                  function Whole_End is new Run_End (Cut_Whole);
               begin
                  return (if Cut_Whole (Here) then Whole_End (From) else 0);
               end;

            when Trailing_Spaces =>
               --  "\s+$": whitespace that runs to the end of the piece.
               declare
                  Stop : constant Natural := Spaces_End (From);
               begin
                  return (if Stop >= From and then Stop = Hi then Stop
                          else 0);
               end;

            when Space_Led_Letters =>
               if Is_Space (Here) and then Is_Letter (At_Point (From + 1))
               then
                  return Letters_End (From + 1);
               elsif Is_Letter (Here) then
                  return Letters_End (From);
               end if;
               return 0;

            when Space_Led_Punctuation =>
               declare
                  function Stops_End is new Run_End (Is_Punctuation);
               begin
                  if Is_Space (Here)
                    and then Is_Punctuation (At_Point (From + 1))
                  then
                     return Stops_End (From + 1);
                  elsif Is_Punctuation (Here) then
                     return Stops_End (From);
                  end if;
                  return 0;
               end;

            when DeepSeek_Words =>
               declare
                  function Named (Code_Point : Natural) return Boolean
                  is (Within (Code_Point, DeepSeek_Letters));
                  function Named_End is new Run_End (Named);
               begin
                  if Is_Space (Here) and then Named (At_Point (From + 1))
                  then
                     return Named_End (From + 1);
                  elsif Named (Here) then
                     return Named_End (From);
                  end if;
                  return 0;
               end;

            when DeepSeek_Stops =>
               declare
                  function Named (Code_Point : Natural) return Boolean
                  is (Listed (Code_Point, DeepSeek_Punctuation));
                  function Named_End is new Run_End (Named);
               begin
                  if Is_Space (Here) and then Named (At_Point (From + 1))
                  then
                     return Named_End (From + 1);
                  elsif Named (Here) then
                     return Named_End (From);
                  end if;
                  return 0;
               end;

            when Chameleon_Spaces =>
               --  A tab or a line feed, else four spaces, else two.
               if Here in 9 | 10 then
                  return From;
               elsif Here = 32 and then At_Point (From + 1) = 32 then
                  if At_Point (From + 2) = 32 and then At_Point (From + 3) = 32
                  then
                     return From + 3;
                  end if;
                  return From + 1;
               end if;
               return 0;

            when Chameleon_Stops =>
               return (if Is_Punctuation (Here)
                         or else Is_ASCII_Punctuation (Here)
                       then From else 0);

            when Chameleon_Sentinels =>
               --  "<sentinel:[0-9]+>", spelled out.
               declare
                  Word  : constant String := "<sentinel:";
                  Index : Natural := From;
               begin
                  for Letter of Word loop
                     if At_Point (Index) /= Character'Pos (Letter) then
                        return 0;
                     end if;
                     Index := Index + 1;
                  end loop;
                  if not Is_ASCII_Digit (At_Point (Index)) then
                     return 0;
                  end if;
                  Index := ASCII_Digits_End (Index) + 1;
                  return (if At_Point (Index) = Character'Pos ('>')
                          then Index else 0);
               end;

            when Chameleon_Images =>
               --  "(IMGIMG)((A|B|C|D|E|F|G|H|I){1,4})Z": the word, one to
               --  four letters from A to I, and a Z. Greedy on the
               --  letters and backtracking for the Z, which a fifth
               --  letter cannot be.
               declare
                  Word  : constant String := "IMGIMG";
                  Index : Natural := From;
                  Taken : Natural := 0;
               begin
                  for Letter of Word loop
                     if At_Point (Index) /= Character'Pos (Letter) then
                        return 0;
                     end if;
                     Index := Index + 1;
                  end loop;
                  while Taken < 4
                    and then At_Point (Index) in 65 .. 73
                  loop
                     Index := Index + 1;
                     Taken := Taken + 1;
                  end loop;
                  return (if Taken > 0
                            and then At_Point (Index) = Character'Pos ('Z')
                          then Index else 0);
               end;
         end case;
      end Match_End;

      --  Run one pass over one piece: every match a piece, and what lies
      --  between two matches a piece.
      procedure Split (Step : Pass) is
         From    : Natural := Lo;
         Pending : Natural := Lo;
      begin
         while From <= Hi loop
            declare
               Stop : constant Natural := Match_End (From, Step);
            begin
               if Stop = Boundary then
                  if From > Pending then
                     Made := Made + 1;
                     After (Made) := From - 1;
                     Pending := From;
                  end if;
                  From := From + 1;
               elsif Stop >= From then
                  if From > Pending then
                     Made := Made + 1;
                     After (Made) := From - 1;
                  end if;
                  Made := Made + 1;
                  After (Made) := Stop;
                  From := Stop + 1;
                  Pending := From;
               else
                  From := From + 1;
               end if;
            end;
         end loop;

         if Pending <= Hi then
            Made := Made + 1;
            After (Made) := Hi;
         end if;
      end Split;

      Steps : constant Pass_List := Passes (Rule);
   begin
      --  Decode once, so that every pass reads code points and asks the
      --  standard library nothing about bytes.
      declare
         Index : Natural := Text'First;
      begin
         while Index <= Text'Last loop
            declare
               Code, Width : Natural;
            begin
               Model_Runner.UTF8.Decode_First
                 (Text (Index .. Text'Last), Code, Width);
               if Width = 0 then
                  Width := 1;
               end if;
               Total := Total + 1;
               Points (Total) := Code;
               Starts (Total) := Index;
               Index := Index + Width;
            end;
         end loop;
         Starts (Total + 1) := Text'Last + 1;
      end;

      if Total > 0 then
         Held := 1;
         Before (1) := Total;
      end if;

      for Step of Steps loop
         Made := 0;
         Lo := 1;
         for Piece in 1 .. Held loop
            Hi := Before (Piece);
            Split (Step);
            Lo := Hi + 1;
         end loop;

         declare
            Swap : constant Point_Array_Access := Before;
         begin
            Before := After;
            After := Swap;
            Held := Made;
         end;
      end loop;

      Ends := new Piece_Ends (1 .. Natural'Max (Held, 1));
      Count := Held;
      for Piece in 1 .. Held loop
         Ends (Piece) := Starts (Before (Piece) + 1) - 1;
      end loop;

      Free_Points (Points);
      Free_Points (Starts);
      Free_Points (Before);
      Free_Points (After);
   end Cut;

end Model_Runner.Tokenizer.Cutting;
