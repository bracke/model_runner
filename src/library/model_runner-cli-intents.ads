with Model_Runner.Framework;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Stores;
with Model_Runner.Presentation;

--  What the project is meant to be, managed in the conversation.
--
--  /req, /decision and /spec each list their register, show an entry, and
--  manage one: new TITLE with text=, criteria= and scope=; accept, reject,
--  reconsider, obsolete, block and unblock; revise ID with title=, text=
--  and criteria=; link ID RELATION TARGET; supersede OLD NEW; and, for a
--  decision or a specification, govern ID SUBJECT RULING with overrides=.
--  Nothing proposed is authoritative until it is accepted, and after every
--  change the project moves along by its own rules -- an accepted
--  requirement derives its task -- without a model.
package Model_Runner.CLI.Intents is

   --  Carry out one of the commands on a register.
   --
   --  @param Store The project's state, open.
   --  @param Kind The register.
   --  @param Words What followed the command, a word each, NAME=VALUE ones
   --    among them.
   --  @param Screen Where to write.
   procedure Run
     (Store  : in out Model_Runner.Framework.Stores.Store;
      Kind   : Model_Runner.Framework.Intent.Intent_Kind;
      Words  : Model_Runner.Framework.Name_Lists.Vector;
      Screen : in out Model_Runner.Presentation.Console);

   --  What waits to be accepted or rejected in the registers, as
   --  KIND:ID -- requirement, specification or decision.
   --
   --  @param Store The project's state.
   --  @return Them.
   function Pending
     (Store : Model_Runner.Framework.Stores.Store)
      return Model_Runner.Framework.Name_Lists.Vector;

   --  Accept or reject one of them, given as Pending writes it.
   --
   --  @param Store The project's state, open.
   --  @param Which KIND:ID.
   --  @param Accepting Whether to accept it.
   --  @param Screen Where to write.
   procedure Decide
     (Store     : in out Model_Runner.Framework.Stores.Store;
      Which     : String;
      Accepting : Boolean;
      Screen    : in out Model_Runner.Presentation.Console);

end Model_Runner.CLI.Intents;
