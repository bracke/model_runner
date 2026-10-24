with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Stores;

--  What the harness finds for a question about the project, ranked, and the
--  pieces of source it shows for it -- worked out from the repository's
--  graph, the project's records and the files as they are, never by a
--  model.
--
--  Search ranks four kinds of hit. Each is scored by fixed rules, summed as
--  whole numbers, and ties are broken by kind, then name, then line, so the
--  same state and query always give the same list:
--
--  A symbol: 1000 for its full name; 800 for a dotted or :: ending of it;
--  400 for its last part; 150 for a last part a query word begins (three
--  letters or more); 60 for each query word that is one of the parts of its
--  name (split at dots, :: and underscores). In a query of three words or
--  more, a word typed in small letters is a word of a sentence: where the
--  name is written otherwise, it counts only as one of the name's parts.
--  Then for what its comment says -- the comment just before it, or a
--  Python docstring just after the line, up to its first @param or
--  @return: for each query word the comment holds, or one beginning the
--  other where the shorter has four letters or more, ten times the log2
--  of 1 + the tree's comments over those holding it; the sum twice, times
--  the share of the query's words it holds, times 2 over 1 + its length
--  over the mean; at most 350, none where it holds one word of several.
--  One of those it must have.
--  Then 20 for each query word in its file's path, 15 for a declaration
--  in an Ada spec, less 20 for a test file's where the query does not say
--  test, and closeness to the units the work is about: 100 for one of
--  them, 60 for a unit one of them depends on or is used by surely, 30 for
--  one only probably.
--
--  A file: 900 for its path, 600 for its name, 50 for each query word in
--  its path.
--
--  A record -- a requirement, specification, decision, task or
--  observation: 1000 for its identifier; 80 for each query word in its
--  title, 25 for each in its text; 30 more where it is accepted, 40 less
--  where it is superseded, rejected, cancelled or dismissed. Each says how
--  far it is to be taken as said: accepted, proposed, historical, or not
--  authoritative.
--
--  A line of a file's text: for each query word, how often the file holds
--  it, at most 8, times how rare it is across the files -- 10 times the
--  log2 of 1 + files over files holding it -- a quarter of that, and 150
--  more where a line holds the query's words in a row; at most 500. The
--  line shown is the first holding the most of the words. Every file that
--  150 more could lift among the first asked for is read for it.
--
--  A file is read by walking its path down from the tree, following no
--  link on the way (Hostkit.Fs.Read_Beneath): a link, or a directory on
--  the way that is one -- even one swapped in during the read -- is not
--  read through.
--
--  An excerpt is the lines a declaration takes, as Repository.Extent_Of
--  finds them in the file as it is now -- the symbol found again where the
--  file changed since the graph was made -- with where it is from, how it
--  was bounded, and the print of the text it was cut from.
--
--  Task safety: the index of the files' words is shared by every task and
--  held under a lock, taken only to find what is to be read, to install
--  what was read and to score: files are read and their words counted
--  without it, so one tree's reading does not hold up another's search.
--  The index visits, for each word of a query, the files that hold it; a
--  word no indexed file holds any more leaves it.
--
--  A file's entry is what was read of it, under the print of what was
--  read, and is installed only where no other pass installed or dropped
--  it since this one chose to read it: a slower pass does not put back
--  an older read, nor a file another found deleted. A file changed after
--  it was read is held under the older text's own print, which the next
--  search's graph -- checked against the tree first -- does not match,
--  so it is read again then. A file that could not be read is not held,
--  and is read again by the next search; one too large is held with no
--  words; Not_Searched names both. A change to the index stopped part
--  way lets the whole index go, to be read anew: every pass under way
--  then installs nothing more, its changes seen before the index went.
--  A file whose reading in raised is passed by, named by Not_Searched
--  with what failed. Where memory ran out it is tried again after a wait
--  that doubles each time, four tries at most until it changes; any
--  other exception is a fault of the program's own, said with where it
--  was raised and not tried again until the file changes: a fault that passes is got
--  over, and one that comes back costs a few tries a version of the
--  file, not a whole index at every search. A pass that let the index go
--  reads in nothing more. What is kept
--  of files gone, for passes under way, is let go once none is.
--
--  What a search's answer stands for, a change to the tree under way:
--  its symbols are the graph's, checked against the tree as the search
--  begins; each scoring pass -- descriptions, then words -- is made
--  under one hold of the lock and sees one state of the index; the line
--  a text hit shows is read from the file as it is then, and one whose
--  file cannot be read by then is left out. A file changed in between is
--  ranked by what it held and shown as it holds. Nothing stronger is
--  promised: an excerpt carries its file's print and is read again only
--  while the file still has it (Expand), and a task's context rests on
--  every file's print (Context's dependencies), so what was built from a
--  tree since changed is found stale there.
package Model_Runner.Framework.Retrieval is

   package U renames Ada.Strings.Unbounded;

   --  What a hit is.
   type Hit_Kind is (Symbol_Hit, File_Hit, Record_Hit, Text_Hit);

   --  One thing found.
   type Hit is record
      Kind      : Hit_Kind := Symbol_Hit;

      --  A symbol's full name, a file's path, a record's identifier, or
      --  the path a line is in.
      Name      : U.Unbounded_String;

      --  A symbol's kind; a file's language and role; a record's kind and
      --  title; a line's text.
      What      : U.Unbounded_String;
      Path      : U.Unbounded_String;
      Line      : Natural := 0;
      Score     : Natural := 0;

      --  Why it scored, as the rules above say it.
      Why       : U.Unbounded_String;

      --  How far it is to be taken as said: accepted, proposed,
      --  historical, not authoritative, or derived from the code.
      Authority : U.Unbounded_String;
   end record;

   package Hit_Lists is new Ada.Containers.Vectors (Positive, Hit);

   --  Whether a path may be read by whoever asks.
   type Path_Check is access function (Path : String) return Boolean;

   --  The longest query taken; a longer one is cut.
   Query_Most : constant := 400;

   --  The largest file whose words are indexed: a generated table of
   --  megabytes says nothing a question is about.
   Indexed_Most : constant := 1_048_576;

   --  Find what a query is about.
   --
   --  @param Store The store, for its records; its project's tree for
   --    text where Root is "".
   --  @param Graph The repository's graph; checked against the tree first
   --    (Repository.Is_Current) and brought up to it where it is not, so a
   --    file added, changed or removed since it was made is searched as it
   --    is now, whoever made the graph and when.
   --  @param Root The tree text is read from.
   --  @param Query Names, paths, identifiers, words.
   --  @param Most How many hits at most.
   --  @param Near The units the work is about, for closeness; none for
   --    none.
   --  @param May_Read Whether a path may be shown; null for every path.
   --  @param Records Whether records are searched: false for one who may
   --    not read the specifications.
   --  @return The hits, best first.
   function Search
     (Store    : Stores.Store;
      Graph    : Repository.Graph;
      Root     : String;
      Query    : String;
      Most     : Positive := 20;
      Near     : Name_Lists.Vector := Name_Lists.Empty_Vector;
      May_Read : Path_Check := null;
      Records  : Boolean := True) return Hit_Lists.Vector;

   --  What a search of a tree did not search: the files its graph could
   --  not read, and those the index could not read, could not index or
   --  holds no words of, being too large -- each as PATH: why, sorted. One
   --  that could not be indexed says what failed (the exception's name and
   --  what was being done) and, for memory run out, how often and when it
   --  is tried again; for a fault of the program's own, the first of its
   --  message. Said beside a search's
   --  hits, so that nothing found there is not taken for nothing there.
   --
   --  @param Graph The graph the search was given.
   --  @param Root The tree searched, as Search's Root; not "".
   --  @return The files, each with why.
   function Not_Searched (Graph : Repository.Graph; Root : String) return Name_Lists.Vector;

   --  The words a query is taken as: each word lowered, and the parts of a
   --  dotted or underscored one; the same words a file's text is indexed
   --  by.
   --
   --  @param Query The query.
   --  @return The words, each once, in the order said.
   function Terms_Of (Query : String) return Name_Lists.Vector;

   --  A piece of a file shown, and where it came from.
   type Excerpt is record
      Path        : U.Unbounded_String;
      Language    : U.Unbounded_String;

      --  The symbol it is the declaration of; "" for a run of lines.
      Symbol      : U.Unbounded_String;
      First       : Natural := 0;
      Last        : Natural := 0;

      --  Whether its lines are the declaration's own, its end found.
      Structural  : Boolean := False;

      --  Whether it was cut to the lines asked for, the rest not shown.
      Truncated   : Boolean := False;

      --  Whether the symbol was found somewhere else than the graph says:
      --  the file changed after the graph was made.
      Moved       : Boolean := False;

      --  The print of the file's text it was cut from.
      Fingerprint : U.Unbounded_String;

      --  Why it is shown.
      Reason      : U.Unbounded_String;
      Text        : U.Unbounded_String;
   end record;

   package Excerpt_Lists is new Ada.Containers.Vectors (Positive, Excerpt);

   --  How many declarations of one name are shown, an overloaded one's.
   Declarations_Most : constant := 4;

   --  The declarations of a name: each symbol it matches, as Find_Symbols
   --  finds them, cut from its file as it is now.
   --
   --  @param Graph The graph; brought up to the tree first, so a symbol in
   --    a file added since it was made is found.
   --  @param Root The tree the files are read from.
   --  @param Name A full name, or the end of one.
   --  @param Most_Lines How many lines one shows at most.
   --  @param Found The excerpts, by name; at most Declarations_Most.
   --  @param Status Framework_Not_Found where the name is no symbol's, or
   --    its file will not read.
   --  @param May_Read Whether a path may be shown; null for every path.
   procedure Declaration
     (Graph      : Repository.Graph;
      Root       : String;
      Name       : String;
      Most_Lines : Positive;
      Found      : out Excerpt_Lists.Vector;
      Status     : out Model_Runner.Errors.Error_Info;
      May_Read   : Path_Check := null);

   --  The declaration holding a line of a file -- the body a use is in --
   --  or a run of lines around it where no declaration holds it.
   --
   --  @param Root The tree.
   --  @param Path The file, within it.
   --  @param Line The line.
   --  @param Most_Lines How many lines it shows at most.
   --  @param Result The excerpt.
   --  @param Status Framework_Not_Found where the file will not read or is
   --    shorter.
   procedure Around
     (Root       : String;
      Path       : String;
      Line       : Positive;
      Most_Lines : Positive;
      Result     : out Excerpt;
      Status     : out Model_Runner.Errors.Error_Info);

   --  What names an excerpt again: PATH:FIRST-LAST@PRINT.
   --
   --  @param From The excerpt.
   --  @return The reference.
   function Reference (From : Excerpt) return String;

   --  An excerpt named by a reference, with as many lines as are asked
   --  for: refused where the file is no longer the text it was cut from,
   --  so lines shown are never other lines than the ones it named.
   --
   --  @param Root The tree.
   --  @param Named The reference.
   --  @param Most_Lines How many lines it shows at most.
   --  @param Result The excerpt.
   --  @param Status Framework_Input_Invalid for no reference, or one whose
   --    file has changed; Framework_Not_Found where it will not read.
   procedure Expand
     (Root       : String;
      Named      : String;
      Most_Lines : Positive;
      Result     : out Excerpt;
      Status     : out Model_Runner.Errors.Error_Info);

   --  An excerpt's line of where it is from: its path and lines, its
   --  symbol, how it was bounded, its reference.
   --
   --  @param From The excerpt.
   --  @return The line.
   function Provenance (From : Excerpt) return String;

   --  Forget the index of the files' words, for a test to build it again.
   procedure Forget;

   --  Let go of what the index holds of a tree and every tree beneath it:
   --  a workspace's, once the workspace is removed. A tree whose root is
   --  gone is let go by the next search of any tree as well, however it
   --  went.
   --
   --  @param Root The tree.
   procedure Forget_Tree (Root : String);

   --  How many files' words the index has read since it was made or
   --  forgotten: what tells an index brought up to date from one read
   --  again.
   --
   --  @return The count.
   function Indexed_Reads return Natural;

   --  How many files' words the index holds now, of every tree: a file
   --  deleted or renamed is let go when the next search finds it gone.
   --
   --  @return The count.
   function Indexed_Held return Natural;

   --  How many terms the index's dictionary holds now, of every tree: a
   --  term no indexed file holds any more is let go with the last file
   --  that held it.
   --
   --  @return The count.
   function Indexed_Terms return Natural;

   --  How long a file whose indexing failed waits before it is tried
   --  again, the first time: doubled each time after; a wait under way
   --  longer than it is cut to it. Held to 0 .. 3,600 seconds. For tests
   --  only -- every tree's files wait alike -- and 30 seconds where nobody
   --  sets it.
   --
   --  @param Wait The wait.
   procedure Retry_Indexing_After (Wait : Duration);

   --  How long a search waits at most for files another search's pass is
   --  reading: what is still being read then is named by Not_Searched.
   --  For tests only; a minute where nobody sets it.
   --
   --  @param Most The wait, held to 0 .. 3,600 seconds.
   procedure Wait_For_Claims_At_Most (Most : Duration);

   --  How many files' last changes the index keeps, for passes under
   --  way: none once no pass is, however many files came and went.
   --
   --  @return The count.
   function Indexed_Changes return Natural;

   --  How many files searches and excerpts have read since the program
   --  began, the index's reading among them: what a measure of a search's
   --  cost takes the difference of.
   --
   --  @return The count.
   function Files_Read return Natural;

end Model_Runner.Framework.Retrieval;
