with Ada.Containers.Vectors;
with Ada.Wide_Wide_Characters.Handling;

with Model_Runner.UTF8;

package body Regex_Cutter is

   package Handling renames Ada.Wide_Wide_Characters.Handling;

   ------------------------------------------------------------------------
   --  Unicode categories, from the database rather than from the engine
   ------------------------------------------------------------------------

   type Span is record
      First : Natural;
      Last  : Natural;
   end record;

   type Span_Table is array (Positive range <>) of Span;

   function Within (Code_Point : Natural; Table : Span_Table) return Boolean
   is (for some Item of Table => Code_Point in Item.First .. Item.Last);

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
   Titlecase : constant Span_Table :=
     [(453, 453), (456, 456), (459, 459), (498, 498), (8072, 8079),
      (8088, 8095), (8104, 8111), (8124, 8124), (8140, 8140), (8188, 8188)];
   Enclosing : constant Span_Table :=
     [(1160, 1161), (6846, 6846), (8413, 8416), (8418, 8420), (42608, 42610)];

   --  Han, as the Kimi K2 rule's \p{Han} names it in the other runtime.
   Han : constant Span_Table :=
     [(16#3400#, 16#4DBF#), (16#4E00#, 16#9FFF#), (16#F900#, 16#FAFF#),
      (16#20000#, 16#2A6DF#), (16#2A700#, 16#2B73F#), (16#2B740#, 16#2B81F#),
      (16#2B820#, 16#2CEAF#), (16#2CEB0#, 16#2EBEF#), (16#2F800#, 16#2FA1F#)];

   function Wide (Code_Point : Natural) return Wide_Wide_Character
   is (Wide_Wide_Character'Val (Code_Point));

   --  The categories an expression may name.
   type Category is
     (Cat_L, Cat_N, Cat_P, Cat_S, Cat_M, Cat_Lu, Cat_Ll, Cat_Lt, Cat_Lm,
      Cat_Lo, Cat_Han);

   function In_Category (Code_Point : Natural; Which : Category)
     return Boolean
   is
      W : constant Wide_Wide_Character := Wide (Code_Point);
   begin
      case Which is
         when Cat_L   => return Handling.Is_Letter (W);
         when Cat_N   => return Handling.Is_Digit (W)
                           or else Within (Code_Point, Other_Numbers);
         when Cat_P   => return Within (Code_Point, Punctuation);
         when Cat_S   => return Within (Code_Point, Symbols);
         when Cat_M   => return Handling.Is_Mark (W)
                           or else Within (Code_Point, Enclosing);
         when Cat_Lu  => return Handling.Is_Upper (W);
         when Cat_Ll  => return Handling.Is_Lower (W);
         when Cat_Lt  => return Within (Code_Point, Titlecase);
         when Cat_Lm | Cat_Lo =>
            --  The two are always named together in the expressions, so
            --  telling them apart would decide nothing.
            return Handling.Is_Letter (W)
              and then not Handling.Is_Upper (W)
              and then not Handling.Is_Lower (W)
              and then not Within (Code_Point, Titlecase);
         when Cat_Han => return Within (Code_Point, Han);
      end case;
   end In_Category;

   function Is_Space (Code_Point : Natural) return Boolean
   is (Code_Point in 32 | 9 | 10 | 11 | 12 | 13
       or else Handling.Is_Space (Wide (Code_Point))
       or else Handling.Is_Line_Terminator (Wide (Code_Point)));

   ------------------------------------------------------------------------
   --  The parsed expression
   ------------------------------------------------------------------------

   --  One item of a character class.
   type Item_Kind is (Item_Range, Item_Category, Item_Space, Item_Digit);

   type Class_Item is record
      Kind   : Item_Kind := Item_Range;
      First  : Natural := 0;
      Last   : Natural := 0;
      Which  : Category := Cat_L;
      --  Whether the item is the complement, \S against \s.
      Negate : Boolean := False;
   end record;

   package Item_Vectors is new Ada.Containers.Vectors (Positive, Class_Item);

   type Node_Kind is (Literal, Class, Group, Repeat, Look, End_Anchor);

   subtype Node_Id is Natural;
   subtype Seq_Id is Natural;

   package Id_Vectors is new Ada.Containers.Vectors (Positive, Natural);

   type Node is record
      Kind    : Node_Kind := Literal;
      Code    : Natural := 0;                 --  Literal
      Items   : Item_Vectors.Vector;          --  Class
      Negated : Boolean := False;             --  Class, Look
      Alts    : Id_Vectors.Vector;            --  Group: its sequences
      Body_Of : Seq_Id := 0;                  --  Repeat, Look
      Least   : Natural := 0;                 --  Repeat
      Most    : Natural := Natural'Last;      --  Repeat
   end record;

   package Node_Vectors is new Ada.Containers.Vectors (Positive, Node);

   --  A sequence is a list of node ids.
   package Seq_Vectors is
     new Ada.Containers.Vectors (Positive, Id_Vectors.Vector, Id_Vectors."=");

   type Pattern is record
      Nodes : Node_Vectors.Vector;
      Seqs  : Seq_Vectors.Vector;
      Root  : Seq_Id := 0;
      Ok    : Boolean := False;
   end record;

   ------------------------------------------------------------------------
   --  Parsing
   ------------------------------------------------------------------------

   type Point_Array is array (Positive range <>) of Natural;

   --  The expression as code points, so that a range in a class may run
   --  between two ideographs as easily as between two letters.
   function Decoded (Text : String) return Point_Array is
      Result : Point_Array (1 .. Text'Length);
      Count  : Natural := 0;
      Index  : Natural := Text'First;
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
            Count := Count + 1;
            Result (Count) := Code;
            Index := Index + Width;
         end;
      end loop;
      return Result (1 .. Count);
   end Decoded;

   procedure Parse (Text : String; Into : out Pattern) is
      Source : constant Point_Array := Decoded (Text);
      At_Pos : Natural := Source'First;
      Failed : Boolean := False;

      function Peek return Natural
      is (if At_Pos <= Source'Last then Source (At_Pos) else 0);

      function More return Boolean is (At_Pos <= Source'Last);

      procedure Take is
      begin
         At_Pos := At_Pos + 1;
      end Take;

      function Next_Is (Letter : Character) return Boolean
      is (More and then Peek = Character'Pos (Letter));

      function New_Node (Item : Node) return Node_Id is
      begin
         Into.Nodes.Append (Item);
         return Node_Id (Into.Nodes.Last_Index);
      end New_Node;

      function New_Seq return Seq_Id is
      begin
         Into.Seqs.Append (Id_Vectors.Empty_Vector);
         return Seq_Id (Into.Seqs.Last_Index);
      end New_Seq;

      procedure Append (Seq : Seq_Id; N : Node_Id) is
         V : Id_Vectors.Vector := Into.Seqs (Seq);
      begin
         V.Append (N);
         Into.Seqs.Replace_Element (Seq, V);
      end Append;

      function Parse_Alternation return Node_Id;

      --  A category name after \p{, up to the brace.
      function Parse_Category return Category is
         Name : String (1 .. 8);
         Used : Natural := 0;
      begin
         if not Next_Is ('{') then
            Failed := True;
            return Cat_L;
         end if;
         Take;
         while More and then not Next_Is ('}') and then Used < Name'Last loop
            Used := Used + 1;
            Name (Used) := Character'Val (Peek);
            Take;
         end loop;
         if not Next_Is ('}') then
            Failed := True;
            return Cat_L;
         end if;
         Take;
         declare
            Word : constant String := Name (1 .. Used);
         begin
            if Word = "L" then
               return Cat_L;
            elsif Word = "N" then
               return Cat_N;
            elsif Word = "P" then
               return Cat_P;
            elsif Word = "S" then
               return Cat_S;
            elsif Word = "M" then
               return Cat_M;
            elsif Word = "Lu" then
               return Cat_Lu;
            elsif Word = "Ll" then
               return Cat_Ll;
            elsif Word = "Lt" then
               return Cat_Lt;
            elsif Word = "Lm" then
               return Cat_Lm;
            elsif Word = "Lo" then
               return Cat_Lo;
            elsif Word = "Han" then
               return Cat_Han;
            end if;
            Failed := True;
            return Cat_L;
         end;
      end Parse_Category;

      --  A code point written as \x{...}, the braces just taken. The
      --  expressions the other runtime holds write ideographs as
      --  themselves; here they are written this way, so that the source
      --  stays ASCII and means the same.
      function Parse_Hex return Natural is
         Value : Natural := 0;
      begin
         if not Next_Is ('{') then
            Failed := True;
            return 0;
         end if;
         Take;
         while More and then not Next_Is ('}') loop
            declare
               C : constant Natural := Peek;
            begin
               if C in 48 .. 57 then
                  Value := Value * 16 + (C - 48);
               elsif C in 65 .. 70 then
                  Value := Value * 16 + (C - 55);
               elsif C in 97 .. 102 then
                  Value := Value * 16 + (C - 87);
               else
                  Failed := True;
                  return 0;
               end if;
            end;
            Take;
         end loop;
         if not Next_Is ('}') then
            Failed := True;
            return 0;
         end if;
         Take;
         return Value;
      end Parse_Hex;

      --  One escaped or plain character inside a class, as a class item.
      --  Escapes of a category, of whitespace and of a digit are items in
      --  their own right; every other escape is the character.
      procedure Parse_Class_Atom (Item : out Class_Item) is
         Code : Natural;
      begin
         Item := (others => <>);
         if Next_Is ('\') then
            Take;
            case Character'Val (Peek) is
               when 'x' =>
                  Take;
                  Code := Parse_Hex;
               when 'p' =>
                  Take;
                  Item := (Kind => Item_Category, Which => Parse_Category,
                           others => <>);
                  return;
               when 's' =>
                  Take;
                  Item := (Kind => Item_Space, others => <>);
                  return;
               when 'S' =>
                  Take;
                  Item := (Kind => Item_Space, Negate => True, others => <>);
                  return;
               when 'd' =>
                  Take;
                  Item := (Kind => Item_Digit, others => <>);
                  return;
               when 'r' => Code := 13; Take;
               when 'n' => Code := 10; Take;
               when 't' => Code := 9; Take;
               when others => Code := Peek; Take;
            end case;
         else
            Code := Peek;
            Take;
         end if;

         Item := (Kind => Item_Range, First => Code, Last => Code,
                  others => <>);

         --  A range, which the expressions write between two plain or
         --  escaped characters.
         if Next_Is ('-') and then At_Pos < Source'Last
           and then Source (At_Pos + 1) /= Character'Pos (']')
         then
            Take;
            declare
               Upper : Class_Item;
            begin
               Parse_Class_Atom (Upper);
               if Upper.Kind /= Item_Range then
                  Failed := True;
                  return;
               end if;
               Item.Last := Upper.First;
            end;
         end if;
      end Parse_Class_Atom;

      function Parse_Class return Node_Id is
         Result : Node := (Kind => Class, others => <>);
      begin
         Take;  --  [
         if Next_Is ('^') then
            Result.Negated := True;
            Take;
         end if;
         while More and then not Next_Is (']') loop
            declare
               Item : Class_Item;
            begin
               Parse_Class_Atom (Item);
               Result.Items.Append (Item);
            end;
            exit when Failed;
         end loop;
         if not Next_Is (']') then
            Failed := True;
         else
            Take;
         end if;
         return New_Node (Result);
      end Parse_Class;

      --  An atom: a group, a class, an escape or a literal.
      function Parse_Atom return Node_Id is
      begin
         if Next_Is ('(') then
            Take;
            if Next_Is ('?') then
               Take;
               if Next_Is (':') then
                  Take;
                  declare
                     G : constant Node_Id := Parse_Alternation;
                  begin
                     if not Next_Is (')') then
                        Failed := True;
                     else
                        Take;
                     end if;
                     return G;
                  end;
               elsif Next_Is ('=') or else Next_Is ('!') then
                  declare
                     Negated : constant Boolean := Next_Is ('!');
                     Inner   : Node_Id;
                     Seq     : Seq_Id;
                  begin
                     Take;
                     Inner := Parse_Alternation;
                     if not Next_Is (')') then
                        Failed := True;
                     else
                        Take;
                     end if;
                     Seq := New_Seq;
                     Append (Seq, Inner);
                     return New_Node
                       ((Kind => Look, Negated => Negated, Body_Of => Seq,
                         others => <>));
                  end;
               end if;
               Failed := True;
               return New_Node ((Kind => Literal, others => <>));
            end if;
            declare
               G : constant Node_Id := Parse_Alternation;
            begin
               if not Next_Is (')') then
                  Failed := True;
               else
                  Take;
               end if;
               return G;
            end;
         elsif Next_Is ('[') then
            return Parse_Class;
         elsif Next_Is ('$') then
            Take;
            return New_Node ((Kind => End_Anchor, others => <>));
         elsif Next_Is ('\') then
            Take;
            case Character'Val (Peek) is
               when 'p' =>
                  Take;
                  declare
                     Result : Node := (Kind => Class, others => <>);
                  begin
                     Result.Items.Append
                       (Class_Item'(Kind => Item_Category,
                                    Which => Parse_Category, others => <>));
                     return New_Node (Result);
                  end;
               when 's' | 'S' =>
                  declare
                     Result : Node := (Kind => Class, others => <>);
                  begin
                     Result.Items.Append
                       (Class_Item'(Kind => Item_Space, Negate => Next_Is ('S'),
                                    others => <>));
                     Take;
                     return New_Node (Result);
                  end;
               when 'd' =>
                  Take;
                  declare
                     Result : Node := (Kind => Class, others => <>);
                  begin
                     Result.Items.Append
                       (Class_Item'(Kind => Item_Digit, others => <>));
                     return New_Node (Result);
                  end;
               when 'x' =>
                  Take;
                  return New_Node ((Kind => Literal, Code => Parse_Hex,
                                    others => <>));
               when 'r' =>
                  Take;
                  return New_Node ((Kind => Literal, Code => 13,
                                    others => <>));
               when 'n' =>
                  Take;
                  return New_Node ((Kind => Literal, Code => 10,
                                    others => <>));
               when 't' =>
                  Take;
                  return New_Node ((Kind => Literal, Code => 9,
                                    others => <>));
               when others =>
                  declare
                     Code : constant Natural := Peek;
                  begin
                     Take;
                     return New_Node ((Kind => Literal, Code => Code,
                                       others => <>));
                  end;
            end case;
         else
            declare
               Code : constant Natural := Peek;
            begin
               Take;
               return New_Node ((Kind => Literal, Code => Code,
                                 others => <>));
            end;
         end if;
      end Parse_Atom;

      --  A number in a brace quantifier.
      function Parse_Number return Natural is
         Value : Natural := 0;
      begin
         while More and then Peek in 48 .. 57 loop
            Value := Value * 10 + (Peek - 48);
            Take;
         end loop;
         return Value;
      end Parse_Number;

      --  An atom and the quantifier after it, if any.
      function Parse_Piece return Node_Id is
         Atom  : constant Node_Id := Parse_Atom;
         Least : Natural;
         Most  : Natural;
      begin
         if Next_Is ('?') then
            Take;
            Least := 0;
            Most := 1;
         elsif Next_Is ('*') then
            Take;
            Least := 0;
            Most := Natural'Last;
         elsif Next_Is ('+') then
            Take;
            Least := 1;
            Most := Natural'Last;
         elsif Next_Is ('{') then
            Take;
            Least := Parse_Number;
            if Next_Is (',') then
               Take;
               Most := (if Next_Is ('}') then Natural'Last else Parse_Number);
            else
               Most := Least;
            end if;
            if not Next_Is ('}') then
               Failed := True;
            else
               Take;
            end if;
         else
            return Atom;
         end if;

         declare
            Seq : constant Seq_Id := New_Seq;
         begin
            Append (Seq, Atom);
            return New_Node
              ((Kind => Repeat, Body_Of => Seq, Least => Least,
                Most => Most, others => <>));
         end;
      end Parse_Piece;

      --  Alternatives separated by bars, each a sequence of pieces, as one
      --  group node.
      function Parse_Alternation return Node_Id is
         Result : Node := (Kind => Group, others => <>);
      begin
         loop
            declare
               Seq : constant Seq_Id := New_Seq;
            begin
               while More and then not Next_Is ('|') and then not Next_Is (')') loop
                  Append (Seq, Parse_Piece);
                  exit when Failed;
               end loop;
               Result.Alts.Append (Seq);
            end;
            exit when Failed or else not Next_Is ('|');
            Take;
         end loop;
         return New_Node (Result);
      end Parse_Alternation;
   begin
      Into := (others => <>);
      declare
         Top : constant Node_Id := Parse_Alternation;
      begin
         Into.Root := New_Seq;
         Append (Into.Root, Top);
      end;
      Into.Ok := not Failed and then not More;
   end Parse;

   ------------------------------------------------------------------------
   --  Matching, by backtracking with an explicit continuation
   ------------------------------------------------------------------------

   type Cont_Kind is (Done, In_Seq, In_Repeat);

   type Cont_Node;
   type Cont is access constant Cont_Node;

   type Cont_Node is record
      Kind  : Cont_Kind := Done;
      Seq   : Seq_Id := 0;       --  In_Seq: the sequence and where in it
      Index : Positive := 1;
      Node  : Node_Id := 0;      --  In_Repeat: the repeat, its count so far
      Count : Natural := 0;      --  and where the iteration began
      Began : Natural := 0;
      Rest  : Cont := null;
   end record;

   procedure Cut
     (Text        : String;
      Expressions : Expression_List;
      Ends        : out Ends_Array;
      Count       : out Natural)
   is
      Points : Point_Array (1 .. Text'Length);
      Starts : Point_Array (1 .. Text'Length + 1);
      Total  : Natural := 0;

      --  The pieces so far and the ones being made, as last code points.
      Before : Point_Array (1 .. Text'Length);
      After  : Point_Array (1 .. Text'Length);
      Held   : Natural := 0;
      Made   : Natural := 0;

      --  The piece being cut and the expression cutting it.
      Lo, Hi : Natural := 0;
      P      : Pattern;

      --  Where the last successful match ended: the last code point taken,
      --  which is one less than the position at Done.
      Final : Natural := 0;

      function Run (K : Cont; Pos : Natural) return Boolean;

      function Class_Matches (N : Node; Code : Natural) return Boolean is
         Hit : Boolean := False;
      begin
         for Item of N.Items loop
            case Item.Kind is
               when Item_Range =>
                  Hit := Code in Item.First .. Item.Last;
               when Item_Category =>
                  Hit := In_Category (Code, Item.Which);
               when Item_Space =>
                  Hit := Is_Space (Code) xor Item.Negate;
               when Item_Digit =>
                  Hit := Code in 48 .. 57;
            end case;
            exit when Hit;
         end loop;
         return Hit xor N.Negated;
      end Class_Matches;

      function Try_Repeat
        (Id : Node_Id; Pos : Natural; Done_So_Far : Natural; K : Cont)
         return Boolean
      is
         N : constant Node := P.Nodes (Id);
      begin
         --  Greedy: one more iteration if there may be one, and then what
         --  follows if enough have been done.
         if Done_So_Far < N.Most then
            declare
               Again : aliased constant Cont_Node :=
                 (Kind => In_Repeat, Node => Id, Count => Done_So_Far + 1,
                  Began => Pos, Rest => K, others => <>);
               Inner : aliased constant Cont_Node :=
                 (Kind => In_Seq, Seq => N.Body_Of, Index => 1,
                  Rest => Again'Unchecked_Access, others => <>);
            begin
               if Run (Inner'Unchecked_Access, Pos) then
                  return True;
               end if;
            end;
         end if;
         return Done_So_Far >= N.Least and then Run (K, Pos);
      end Try_Repeat;

      function Match_Node (Id : Node_Id; Pos : Natural; K : Cont)
        return Boolean
      is
         N : constant Node := P.Nodes (Id);
      begin
         case N.Kind is
            when Literal =>
               return Pos <= Hi and then Points (Pos) = N.Code
                 and then Run (K, Pos + 1);
            when Class =>
               return Pos <= Hi and then Class_Matches (N, Points (Pos))
                 and then Run (K, Pos + 1);
            when Group =>
               for Alt of N.Alts loop
                  declare
                     Inner : aliased constant Cont_Node :=
                       (Kind => In_Seq, Seq => Alt, Index => 1, Rest => K,
                        others => <>);
                  begin
                     if Run (Inner'Unchecked_Access, Pos) then
                        return True;
                     end if;
                  end;
               end loop;
               return False;
            when Repeat =>
               return Try_Repeat (Id, Pos, 0, K);
            when Look =>
               declare
                  Stop  : aliased constant Cont_Node :=
                    (Kind => Done, others => <>);
                  Inner : aliased constant Cont_Node :=
                    (Kind => In_Seq, Seq => N.Body_Of, Index => 1,
                     Rest => Stop'Unchecked_Access, others => <>);
                  Saw   : constant Boolean :=
                    Run (Inner'Unchecked_Access, Pos);
               begin
                  return (Saw xor N.Negated) and then Run (K, Pos);
               end;
            when End_Anchor =>
               return Pos = Hi + 1 and then Run (K, Pos);
         end case;
      end Match_Node;

      function Run (K : Cont; Pos : Natural) return Boolean is
      begin
         case K.Kind is
            when Done =>
               Final := Pos - 1;
               return True;
            when In_Seq =>
               declare
                  Seq : constant Id_Vectors.Vector := P.Seqs (K.Seq);
               begin
                  if K.Index > Seq.Last_Index then
                     return Run (K.Rest, Pos);
                  end if;
                  declare
                     Next : aliased constant Cont_Node :=
                       (Kind => In_Seq, Seq => K.Seq, Index => K.Index + 1,
                        Rest => K.Rest, others => <>);
                  begin
                     return Match_Node
                       (Seq (K.Index), Pos, Next'Unchecked_Access);
                  end;
               end;
            when In_Repeat =>
               --  An iteration that took nothing is the last, or the
               --  loop would never end; what follows is tried from here.
               if Pos = K.Began then
                  return Run (K.Rest, Pos);
               end if;
               return Try_Repeat (K.Node, Pos, K.Count, K.Rest);
         end case;
      end Run;

      --  Whether P matches at From, and where the match ends in Final.
      function Match_At (From : Natural) return Boolean is
         Stop : aliased constant Cont_Node := (Kind => Done, others => <>);
         Top  : aliased constant Cont_Node :=
           (Kind => In_Seq, Seq => P.Root, Index => 1,
            Rest => Stop'Unchecked_Access, others => <>);
      begin
         return Run (Top'Unchecked_Access, From);
      end Match_At;

      --  Cut the piece Lo .. Hi by P: every match a piece, what lies
      --  between matches a piece, and an empty match a boundary.
      procedure Split is
         From    : Natural := Lo;
         Pending : Natural := Lo;
      begin
         while From <= Hi loop
            if Match_At (From) then
               if Final >= From then
                  if From > Pending then
                     Made := Made + 1;
                     After (Made) := From - 1;
                  end if;
                  Made := Made + 1;
                  After (Made) := Final;
                  From := Final + 1;
                  Pending := From;
               else
                  if From > Pending then
                     Made := Made + 1;
                     After (Made) := From - 1;
                     Pending := From;
                  end if;
                  From := From + 1;
               end if;
            else
               From := From + 1;
            end if;
         end loop;

         if Pending <= Hi then
            Made := Made + 1;
            After (Made) := Hi;
         end if;
      end Split;
   begin
      Count := 0;

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

      if Total = 0 then
         return;
      end if;

      Held := 1;
      Before (1) := Total;

      for Which of Expressions loop
         Parse (Which.all, P);
         if not P.Ok then
            return;
         end if;

         Made := 0;
         Lo := 1;
         for Piece in 1 .. Held loop
            Hi := Before (Piece);
            Split;
            Lo := Hi + 1;
         end loop;

         Before (1 .. Made) := After (1 .. Made);
         Held := Made;
      end loop;

      Count := Held;
      for Piece in 1 .. Held loop
         Ends (Ends'First + Piece - 1) := Starts (Before (Piece) + 1) - 1;
      end loop;
   end Cut;

end Regex_Cutter;
