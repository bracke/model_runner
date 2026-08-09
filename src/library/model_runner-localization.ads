private with Ada.Strings.Unbounded;
private with Messages.Runtime;

with Model_Runner.Errors;
with Model_Runner.Text;

--  Localized message resolution.
--
--  This is the only package that depends on the message catalog. Everything
--  below the presentation layer reports structured codes and typed parameters;
--  the text a user reads is produced here and nowhere else.
--
--  Locale precedence, applied by Open:
--
--    1  the explicit --locale value
--    2  MODEL_RUNNER_LOCALE
--    3  the platform locale, from LC_ALL then LANG
--    4  the catalog's own default locale
--    5  the invariant fallback
--    6  the emergency path below
--
--  Emergency path. When the catalog cannot be loaded, or a key cannot be
--  rendered, Text falls back to a fixed invariant form that names the message
--  identifier. That path never calls back into the catalog, so a broken
--  catalog produces one useless-but-honest line rather than unbounded
--  recursion.
--
--  Task safety: a Catalog is opened once and read afterwards.
package Model_Runner.Localization is

   --  Largest number of named arguments one message may take.
   Max_Arguments : constant := 8;

   --  A resolved message catalog.
   type Catalog is tagged limited private;

   --  A named argument for a message.
   type Argument is record
      Name  : Model_Runner.Text.Bounded;
      Value : Model_Runner.Text.Bounded;
   end record;

   type Argument_List is array (Positive range <>) of Argument;

   Empty_Arguments : constant Argument_List (1 .. 0) := [others => <>];

   --  Build a named argument.
   --
   --  @param Name Placeholder name as the catalog message spells it.
   --  @param Value Replacement text.
   --  @return Argument ready for Text.
   function Named (Name, Value : String) return Argument;

   --  Open a catalog.
   --
   --  Failure is not reported as an error: a program that cannot load its
   --  catalog must still be able to say so. Is_Ready reports the outcome and
   --  every lookup falls back to the emergency form.
   --
   --  @param Item Catalog to open.
   --  @param Path Catalog file path.
   --  @param Requested Explicit locale, or an empty string.
   --  @param Environment Locale from the environment, or an empty string.
   --  @param Platform Locale from the host, or an empty string.
   procedure Open
     (Item        : in out Catalog;
      Path        : String;
      Requested   : String := "";
      Environment : String := "";
      Platform    : String := "");

   --  Release a catalog. Idempotent.
   --
   --  @param Item Catalog to release.
   procedure Close (Item : in out Catalog);

   --  Report whether the catalog loaded and the locale resolved.
   --
   --  @param Item Catalog to inspect.
   --  @return True when ordinary lookups can succeed.
   function Is_Ready (Item : Catalog) return Boolean;

   --  Locale the catalog resolved to.
   --
   --  @param Item Catalog to inspect.
   --  @return Resolved locale identifier; never localized.
   function Locale (Item : Catalog) return String;

   --  Report whether the requested locale was unavailable and a fallback was
   --  used, so that the presentation layer can warn once.
   --
   --  @param Item Catalog to inspect.
   --  @return True when the resolved locale differs from the requested one.
   function Used_Fallback (Item : Catalog) return Boolean;

   --  Locale that actually answered when the requested one was probed.
   --
   --  Locale reports what was asked for. This reports what replied, which is
   --  the same thing until a locale this build does not carry is asked for --
   --  and the warning about that used to name the missing locale twice,
   --  saying it was unavailable and then that it was being used.
   --
   --  @param Item Catalog to inspect.
   --  @return Locale identifier of the entries that answer, never localized.
   function Answering_Locale (Item : Catalog) return String;

   --  Render a message.
   --
   --  @param Item Catalog to read.
   --  @param Key Stable message identifier.
   --  @param Arguments Named arguments the message may reference.
   --  @return Rendered text, or the emergency form naming Key.
   function Text
     (Item      : Catalog;
      Key       : String;
      Arguments : Argument_List := Empty_Arguments) return String;

   --  Report whether a key resolves, without rendering it.
   --
   --  Used by the catalog completeness checks in the tests crate.
   --
   --  @param Item Catalog to read.
   --  @param Key Stable message identifier.
   --  @return True when the key exists for the resolved locale.
   function Has (Item : Catalog; Key : String) return Boolean;

   --  Render a structured condition, using its own typed parameters as the
   --  message arguments.
   --
   --  Parameter values are escaped: a diagnostic may quote a tensor name or a
   --  metadata key that came from an untrusted file, and a terminal must not
   --  act on it.
   --
   --  @param Item Catalog to read.
   --  @param Condition Structured condition to render.
   --  @return Primary diagnostic text.
   function Describe
     (Item      : Catalog;
      Condition : Model_Runner.Errors.Error_Info) return String;

   --  Localized label for a severity.
   --
   --  @param Item Catalog to read.
   --  @param Severity Severity to label.
   --  @return Label text such as "error".
   function Severity_Label
     (Item     : Catalog;
      Severity : Model_Runner.Errors.Severity_Level) return String;

private

   type Catalog is tagged limited record
      Runtime  : Messages.Runtime.Runtime;
      Ready    : Boolean := False;
      Resolved : Ada.Strings.Unbounded.Unbounded_String;
      Answering : Ada.Strings.Unbounded.Unbounded_String;
      Wanted   : Ada.Strings.Unbounded.Unbounded_String;
      Fallback : Boolean := False;
   end record;

end Model_Runner.Localization;
