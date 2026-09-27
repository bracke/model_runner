private with Ada.Containers.Vectors;
private with Ada.Finalization;
private with Hostkit.Locks;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Records;

--  A project's state directory, opened, and changed only by transactions.
--
--  Every record lives in one area of the directory, under a name, as
--  <area>/<name>.rec. A caller reads a record directly and changes one only
--  by staging the change in a transaction and committing it. Committing
--  checks every record against its schema and against the revision it was
--  made from, writes the whole change to a journal, and then marks the
--  journal committed with a single rename. That rename is the moment the
--  change happens: before it, nothing has; after it, all of it has, and
--  applying it to the areas is work that can be done again from the
--  journal as often as it takes to finish.
--
--  Opening the directory finishes what was interrupted. A journal marked
--  committed is applied; one that was not is thrown away, and so is any
--  file a write left half made. The derived index of entities is rebuilt
--  when it is missing or unreadable. What was done is reported, so the
--  caller can say so.
--
--  One session holds a state directory at a time, by an exclusive lock
--  on a file in its runtime area. A second session asking for it is told
--  it is held rather than made to wait.
package Model_Runner.Framework.Stores is

   --  An open state directory.
   type Store is limited private;

   --  What opening a state directory had to put right.
   type Recovery_Report is record
      --  Committed changes an interruption had left unapplied.
      Rolled_Forward   : Natural := 0;

      --  Changes interrupted before they were committed, thrown away.
      Rolled_Back      : Natural := 0;

      --  Files a write had left half made, removed.
      Partials_Removed : Natural := 0;

      --  Whether the entity index had to be built again.
      Index_Rebuilt    : Boolean := False;
   end record;

   --  A change to the state, staged and not yet committed.
   type Transaction is private;

   --  A transaction with nothing in it.
   No_Changes : constant Transaction;

   --  Whether a string can name a record in an area: letters, digits and
   --  the characters _ . -, starting with a letter or digit.
   --
   --  @param Name The candidate.
   --  @return True when Name can name a record.
   function Is_Name (Name : String) return Boolean;

   --  The state directory of a project.
   --
   --  @param Project_Directory The project.
   --  @return Where its state is kept.
   function State_Root (Project_Directory : String) return String;

   --  Whether a project has state.
   --
   --  @param Project_Directory The project.
   --  @return True when its state directory has been made whole.
   function Is_Initialized (Project_Directory : String) return Boolean;

   --  Make a project's state directory and open it.
   --
   --  The state root's own record is written last, so a directory whose
   --  creation was interrupted is one that has not been made, and making
   --  it again finishes the work. What else the state starts with is
   --  committed in the same transaction as the project's identity, so it
   --  is there exactly when the project is.
   --
   --  @param Item The store, open when Status is a success.
   --  @param Project_Directory The project.
   --  @param Project_Name What the project is called.
   --  @param Status Framework_Already_Initialized when the project has
   --    state, Framework_Locked when another session holds it, and a write
   --    or schema failure otherwise.
   --  @param Initial What else the state starts with. A creation that is
   --    finishing an interrupted one keeps what that one committed and
   --    passes this over.
   procedure Create
     (Item              : in out Store;
      Project_Directory : String;
      Project_Name      : String;
      Status            : out Model_Runner.Errors.Error_Info;
      Initial           : Transaction := No_Changes);

   --  Open a project's state directory, finishing what was interrupted.
   --
   --  @param Item The store, open when Status is a success.
   --  @param Project_Directory The project.
   --  @param Report What had to be put right.
   --  @param Status Framework_Not_Initialized when the project has no
   --    state, Framework_Format_Unsupported when a later build wrote it,
   --    Framework_Locked when another session holds it, and
   --    Framework_Recovery_Required when an interrupted change can be
   --    neither finished nor undone.
   procedure Open
     (Item              : in out Store;
      Project_Directory : String;
      Report            : out Recovery_Report;
      Status            : out Model_Runner.Errors.Error_Info);

   --  Let the state directory go. Harmless on a store that is not open.
   --
   --  @param Item The store.
   procedure Close (Item : in out Store);

   --  Whether a store is open.
   --
   --  @param Item The store.
   --  @return True between a successful Open or Create and Close.
   function Is_Open (Item : Store) return Boolean;

   --  The state directory a store has open.
   --
   --  @param Item The store.
   --  @return Its path.
   function Root (Item : Store) return String;

   --  The identifier the project was given when its state was made.
   --
   --  @param Item The store.
   --  @return The project's identifier.
   function Project_Id (Item : Store) return String;

   --  What the project is called.
   --
   --  @param Item The store.
   --  @return Its name.
   function Project_Name (Item : Store) return String;

   --  Read a record and check it against its schema.
   --
   --  @param Item The store.
   --  @param Where Its area.
   --  @param Name Its name.
   --  @param Value The record, when Status is a success.
   --  @param Status Framework_Not_Found when there is no such record, and
   --    a read, format or schema failure otherwise.
   procedure Read
     (Item   : Store;
      Where  : Area;
      Name   : String;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info);

   --  Whether a record is there.
   --
   --  @param Item The store.
   --  @param Where Its area.
   --  @param Name Its name.
   --  @return True when it is.
   function Exists (Item : Store; Where : Area; Name : String) return Boolean;

   --  The records in an area.
   --
   --  @param Item The store.
   --  @param Where The area.
   --  @return Their names, sorted.
   function Names (Item : Store; Where : Area) return Name_Lists.Vector;

   --  The revision a record is at.
   --
   --  @param Item The store.
   --  @param Where Its area.
   --  @param Name Its name.
   --  @return Its revision, or zero when it is not there or cannot be read.
   function Current_Revision
     (Item  : Store;
      Where : Area;
      Name  : String) return Natural;

   --  Stage a record to be written. Its revision must be one past the
   --  revision of the record it replaces, or 1 when it replaces nothing;
   --  that is checked when the transaction commits.
   --
   --  @param Change The transaction.
   --  @param Where Its area.
   --  @param Name Its name.
   --  @param Value The record.
   procedure Put
     (Change : in out Transaction;
      Where  : Area;
      Name   : String;
      Value  : Records.Item);

   --  Stage a record to be removed.
   --
   --  @param Change The transaction.
   --  @param Where Its area.
   --  @param Name Its name.
   procedure Remove
     (Change : in out Transaction;
      Where  : Area;
      Name   : String);

   --  The record a transaction will write in place of a name, if it
   --  stages one: what a second change to the same record in the same
   --  transaction starts from.
   --
   --  @param Change The transaction.
   --  @param Where Its area.
   --  @param Name Its name.
   --  @param Value The staged record, when Found.
   --  @param Found Whether the transaction writes it.
   procedure Pending
     (Change : Transaction;
      Where  : Area;
      Name   : String;
      Value  : out Records.Item;
      Found  : out Boolean);

   --  How many changes a transaction holds.
   --
   --  @param Change The transaction.
   --  @return The count.
   function Change_Count (Change : Transaction) return Natural;

   --  Hand out the next number of a namespace and key, counting it in the
   --  transaction, so that it is taken exactly when the change that uses
   --  it is committed.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Namespace The kind of entity, as EVT.
   --  @param Key What it belongs to; empty for none.
   --  @param Number The number, from 1.
   --  @param Status Framework_Identifier_Invalid when the namespace and key
   --    do not make an identifier.
   procedure Allocate_Number
     (Item      : Store;
      Change    : in out Transaction;
      Namespace : String;
      Key       : String;
      Number    : out Natural;
      Status    : out Model_Runner.Errors.Error_Info);

   --  The identifier of a transaction: TXN- and nine digits, handed out
   --  the first time it is asked for and the same afterwards, until the
   --  transaction is committed. What its events name as their transaction.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id Its identifier.
   --  @param Status A failure to read the counters.
   procedure Identify
     (Item   : Store;
      Change : in out Transaction;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Hand out the next identifier of a namespace and key, counting it in
   --  the transaction, so that it is taken exactly when the change that
   --  uses it is committed.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Namespace The kind of entity, as REQ.
   --  @param Key What it belongs to, as PARSER; empty for none.
   --  @param Id The identifier.
   --  @param Status Framework_Identifier_Invalid when the namespace and key
   --    do not make an identifier.
   procedure Allocate_Identifier
     (Item      : Store;
      Change    : in out Transaction;
      Namespace : String;
      Key       : String;
      Id        : out Ada.Strings.Unbounded.Unbounded_String;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Write a transaction's changes to the journal, without committing it.
   --
   --  Every record is checked here, against its schema and its revision,
   --  and nothing is written when one fails. What is written is thrown
   --  away if the store is opened again before Mark.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Status A schema, revision or name failure, or a write one.
   procedure Stage
     (Item   : in out Store;
      Change : Transaction;
      Status : out Model_Runner.Errors.Error_Info);

   --  Commit what Stage wrote: after this the change has happened, even if
   --  nothing applies it before the store is opened again.
   --
   --  @param Item The store.
   --  @param Status Framework_Transaction_Failed when there is nothing
   --    staged or the mark could not be made.
   procedure Mark
     (Item   : in out Store;
      Status : out Model_Runner.Errors.Error_Info);

   --  Apply a committed journal to the areas and the index, and remove it.
   --  Harmless when there is none, and safe to repeat after an
   --  interruption.
   --
   --  @param Item The store.
   --  @param Status Framework_Recovery_Required when the journal cannot be
   --    read or a change in it has been lost.
   procedure Finish
     (Item   : in out Store;
      Status : out Model_Runner.Errors.Error_Info);

   --  Stage, mark and finish a transaction, and empty it.
   --
   --  @param Item The store.
   --  @param Change The transaction, empty afterwards when Status is a
   --    success.
   --  @param Status What went wrong, if anything.
   procedure Commit
     (Item   : in out Store;
      Change : in out Transaction;
      Status : out Model_Runner.Errors.Error_Info);

   --  Whether a change was left in the journal: staged and never marked,
   --  or marked and never finished. An open store has recovered what it
   --  found, so this is a change made since, or one that could not be
   --  recovered.
   --
   --  @param Item The store.
   --  @return True when the journal holds anything.
   function Journal_Pending (Item : Store) return Boolean;

   --  Build the entity index again from the records.
   --
   --  @param Item The store.
   --  @param Status A read or format failure of a record, when one cannot
   --    be read; the others are indexed.
   procedure Rebuild_Index
     (Item   : in out Store;
      Status : out Model_Runner.Errors.Error_Info);

   --  Where an entity's record is.
   --
   --  @param Item The store.
   --  @param Entity_Id The entity.
   --  @param Where Its area, when Found.
   --  @param Name Its name, when Found.
   --  @param Found Whether the index knows it.
   procedure Lookup
     (Item      : in out Store;
      Entity_Id : String;
      Where     : out Area;
      Name      : out Ada.Strings.Unbounded.Unbounded_String;
      Found     : out Boolean);

private

   use Ada.Strings.Unbounded;

   type Operation_Kind is (Put_Operation, Remove_Operation);

   type Operation is record
      Kind  : Operation_Kind := Put_Operation;
      Where : Area := Project_Area;
      Name  : Unbounded_String;
      Value : Records.Item;
   end record;

   package Operation_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Operation);

   type Transaction is record
      Operations : Operation_Vectors.Vector;
      Id         : Unbounded_String;
   end record;

   No_Changes : constant Transaction :=
     (Operations => Operation_Vectors.Empty_Vector,
      Id         => Null_Unbounded_String);

   type Store is new Ada.Finalization.Limited_Controlled with record
      Root         : Unbounded_String;
      Lock         : Hostkit.Locks.Lock;
      Opened       : Boolean := False;
      Project_Id   : Unbounded_String;
      Project_Name : Unbounded_String;
   end record;

   overriding procedure Finalize (Item : in out Store);

end Model_Runner.Framework.Stores;
