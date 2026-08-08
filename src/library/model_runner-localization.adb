with Messages.Arguments;
with Messages.Result;

package body Model_Runner.Localization is

   use type Messages.Result.Render_Status;
   use type Messages.Runtime.Resolve_Status;
   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Text;

   --  Locale used when nothing else resolves. The catalog always carries this
   --  locale, so the emergency path is only reached when the catalog itself is
   --  unusable.
   Invariant_Locale : constant String := "en";

   -----------
   -- Named --
   -----------

   function Named (Name, Value : String) return Argument
   is (Name => T.To_Bounded (Name), Value => T.To_Bounded (Value));

   --  Reduce a locale such as "de_AT.UTF-8" to the identifier the catalog
   --  understands. The catalog performs its own fallback from a region to a
   --  language; this only strips host encoding and modifier suffixes.
   function Normalize (Item : String) return String is
      Last : Natural := Item'Last;
   begin
      for Index in Item'Range loop
         if Item (Index) = '.' or else Item (Index) = '@' then
            Last := Index - 1;
            exit;
         end if;
      end loop;

      declare
         Trimmed : String := Item (Item'First .. Last);
      begin
         for Index in Trimmed'Range loop
            if Trimmed (Index) = '_' then
               Trimmed (Index) := '-';
            end if;
         end loop;
         return Trimmed;
      end;
   end Normalize;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item        : in out Catalog;
      Path        : String;
      Requested   : String := "";
      Environment : String := "";
      Platform    : String := "")
   is
      --  Locale precedence, most specific first.
      function Preferred return String is
      begin
         if Requested /= "" then
            return Normalize (Requested);
         elsif Environment /= "" then
            return Normalize (Environment);
         elsif Platform /= "" then
            return Normalize (Platform);
         else
            return Invariant_Locale;
         end if;
      end Preferred;

      Wanted : constant String := Preferred;
   begin
      Close (Item);
      Item.Wanted := To_Unbounded_String (Wanted);

      Messages.Runtime.Initialize (Item.Runtime, Path);
      if not Messages.Runtime.Is_Valid (Item.Runtime) then
         Item.Ready := False;
         Item.Resolved := To_Unbounded_String (Invariant_Locale);
         return;
      end if;

      --  Render in the requested locale. The catalog runtime falls back per
      --  key to the default locale, so a partial translation renders its own
      --  messages and inherits the rest; abandoning the whole locale because
      --  one key is missing would discard the part that does exist.
      Item.Resolved := To_Unbounded_String (Wanted);

      --  Probe a key every catalog carries. When it does not resolve in the
      --  requested locale, some or all messages will come from the fallback,
      --  which is worth saying once in verbose mode.
      declare
         Probe : constant Messages.Runtime.Resolve_Result :=
           Messages.Runtime.Resolve (Item.Runtime, Wanted, "application.name");
      begin
         Item.Fallback :=
           Probe.Status /= Messages.Runtime.Found
           or else Messages.Runtime.Resolved_Locale (Probe) /= Wanted;
      end;

      Item.Ready := True;
   exception
      when others =>
         Item.Ready := False;
         Item.Resolved := To_Unbounded_String (Invariant_Locale);
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Catalog) is
   begin
      if Item.Ready then
         Messages.Runtime.Finalize (Item.Runtime);
      end if;
      Item.Ready := False;
      Item.Fallback := False;
      Item.Resolved := Null_Unbounded_String;
      Item.Wanted := Null_Unbounded_String;
   exception
      when others =>
         Item.Ready := False;
   end Close;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready (Item : Catalog) return Boolean is (Item.Ready);

   ------------
   -- Locale --
   ------------

   function Locale (Item : Catalog) return String
   is (To_String (Item.Resolved));

   --------------------
   -- Used_Fallback --
   --------------------

   function Used_Fallback (Item : Catalog) return Boolean is (Item.Fallback);

   ---------
   -- Has --
   ---------

   function Has (Item : Catalog; Key : String) return Boolean is
   begin
      if not Item.Ready then
         return False;
      end if;

      return Messages.Runtime.Resolve
        (Item.Runtime, To_String (Item.Resolved), Key).Status
        = Messages.Runtime.Found;
   exception
      when others =>
         return False;
   end Has;

   ----------
   -- Text --
   ----------

   function Text
     (Item      : Catalog;
      Key       : String;
      Arguments : Argument_List := Empty_Arguments) return String
   is
      --  The emergency form. It names the identifier that could not be
      --  rendered and nothing else, and it never consults the catalog, so a
      --  failure inside localization cannot recurse.
      function Emergency return String is ("<" & Key & ">");

      Values : Messages.Arguments.Arguments;
      Result : Messages.Result.Render_Result;
   begin
      if not Item.Ready then
         return Emergency;
      end if;

      for Entry_Value of Arguments loop
         if not T.Is_Empty (Entry_Value.Name) then
            Messages.Arguments.Set
              (Values, T.To_String (Entry_Value.Name),
               T.To_String (Entry_Value.Value));
         end if;
      end loop;

      Result :=
        Messages.Runtime.Render
          (Item.Runtime, To_String (Item.Resolved), Key, Values);

      if Result.Status = Messages.Result.Success then
         --  Escaped on the way out. The catalog is a file beside the
         --  executable and the specification counts it among the untrusted
         --  inputs, its text reaches a terminal, and a replaced catalog must
         --  not be able to clear a screen or hide what follows any more than
         --  a model file can. Parameters were escaped as they went in and
         --  are plain ASCII by now, so this pass leaves them as they are.
         return T.Escape_Controls (Messages.Result.Output_Text (Result.Text));
      else
         return Emergency;
      end if;
   exception
      when others =>
         return Emergency;
   end Text;

   --------------
   -- Describe --
   --------------

   function Describe
     (Item      : Catalog;
      Condition : E.Error_Info) return String
   is
      Values : Argument_List (1 .. Max_Arguments);
      Used   : Natural := 0;
   begin
      if E.Is_Ok (Condition) then
         return "";
      end if;

      for Index in 1 .. Condition.Parameter_Total loop
         exit when Used = Values'Length;
         Used := Used + 1;
         Values (Used) :=
           Named
             (T.To_String (Condition.Parameters (Index).Name),
              --  Escaped: the value may be a tensor name or a metadata key
              --  from an untrusted file.
              T.Escape_Controls
                (T.To_String (Condition.Parameters (Index).Text_Value)));
      end loop;

      return Text (Item, E.Message_Key (Condition.Code), Values (1 .. Used));
   end Describe;

   ----------------------
   -- Severity_Label --
   ----------------------

   function Severity_Label
     (Item     : Catalog;
      Severity : E.Severity_Level) return String is
   begin
      case Severity is
         when E.Severity_Information =>
            return Text (Item, "diagnostic.label.information");
         when E.Severity_Warning =>
            return Text (Item, "diagnostic.label.warning");
         when E.Severity_Error =>
            return Text (Item, "diagnostic.label.error");
         when E.Severity_Internal =>
            return Text (Item, "diagnostic.label.internal");
      end case;
   end Severity_Label;

end Model_Runner.Localization;
