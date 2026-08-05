with Interfaces;

--  Seed selection.
--
--  Sampling uses a session-local generator seeded from an explicit 64-bit
--  value. When the caller does not supply one, the seed comes from an entropy
--  source through this interface. Tests install a fixed source so that
--  "automatic" seeding is still reproducible, and the chosen seed is reported
--  in verbose statistics so a run can be repeated exactly.
--
--  Task safety: implementations are used by a single session.
package Model_Runner.Entropy is

   subtype Seed_Value is Interfaces.Unsigned_64;

   --  A source of seed values.
   type Source is limited interface;

   --  Produce the next seed.
   --
   --  @param Self Source instance.
   --  @param Seed Selected seed value.
   procedure Next_Seed (Self : in out Source; Seed : out Seed_Value)
   is abstract;

   type Source_Reference is access all Source'Class;

   --  Draw a seed from a possibly absent source.
   --
   --  @param Item Source reference, possibly null.
   --  @param Seed Selected seed; a fixed documented constant when Item is null.
   procedure Draw (Item : Source_Reference; Seed : out Seed_Value);

   --  Seed used when no entropy source is available. Published so that a run
   --  without a source is still reproducible and testable.
   Fallback_Seed : constant Seed_Value := 16#9E37_79B9_7F4A_7C15#;

   --  An entropy source backed by the host clock and process identity.
   --
   --  This is not a cryptographic generator and is not used for anything that
   --  needs one. It only has to make two runs of the same command differ.
   type Host_Source is limited new Source with private;

   --  Produce the next host-derived seed.
   --
   --  @param Self Source instance.
   --  @param Seed Selected seed value.
   overriding procedure Next_Seed
     (Self : in out Host_Source;
      Seed : out Seed_Value);

   --  A source that returns a fixed sequence, used by tests and by
   --  deterministic mode.
   type Fixed_Source is limited new Source with private;

   --  Build a source that always returns the same value.
   --
   --  @param Value Seed to return from every call.
   --  @return Configured source.
   function Fixed (Value : Seed_Value) return Fixed_Source;

   --  Produce the configured fixed seed.
   --
   --  @param Self Source instance.
   --  @param Seed Configured seed value.
   overriding procedure Next_Seed
     (Self : in out Fixed_Source;
      Seed : out Seed_Value);

private

   type Host_Source is limited new Source with record
      Counter : Seed_Value := 0;
   end record;

   type Fixed_Source is limited new Source with record
      Value : Seed_Value := Fallback_Seed;
   end record;

end Model_Runner.Entropy;
