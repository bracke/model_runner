with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Text_IO;

with Model_Runner.CLI.Interactive;
with Model_Runner.CLI.Intents;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.Errors;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Platform;

package body Model_Runner.CLI.Completion is

   package Names renames Model_Runner.Framework.Name_Lists;
   package E renames Model_Runner.Errors;
   package S renames Model_Runner.Framework.Stores;
   package Nt renames Model_Runner.Framework.Intent;
   package Tk renames Model_Runner.Framework.Tasks;
   package R renames Model_Runner.Framework.Records;

   package Sorting is new Names.Generic_Sorting;

   --  The project's own commands, beside the session's.
   Project_Commands : constant String :=
     " /init /bootstrap /state /config /reconfigure /task /accept /reject /work /cancel /check /req /decision"
     & " /spec /result /scan /tree /sym /refs /deps /users /impact /trace /git /sandbox /instruct ";

   --  Words a space apart, as a list.
   function Words_Of (Text : String) return Names.Vector is
      Result : Names.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ' ' then
            if Index > Start then
               Result.Append (Text (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Words_Of;

   --  The actions each command takes as its second word.
   function Actions_Of (Command : String) return String
   is (if Command = "/task"
       then "list new show accept reject cancel reopen reconsider complete verify diff integrate kept edit note"
            & " grant withhold link depend split rehome move plan derive audit context"
       elsif Command = "/req"
       then "list new show accept reject reconsider obsolete verify revise link unlink supersede move block unblock"
       elsif Command in "/spec" | "/decision"
       then "list new show accept reject reconsider obsolete revise link unlink supersede govern"
       elsif Command = "/reconfigure" then "add remove"
       elsif Command = "/result" then "dismiss dismissed restore"
       elsif Command = "/instruct" then "withdraw"
       elsif Command = "/sandbox" then "on off"
       elsif Command = "/check" then "consistency"
       else "");

   --  Every file and directory under a path's directory that its last part
   --  begins: a directory with its slash, to go on into.
   function Paths (Prefix : String) return Names.Vector is
      Result : Names.Vector;
      Slash  : constant Natural := Ada.Strings.Fixed.Index (Prefix, "/", Ada.Strings.Backward);
      Dir    : constant String := (if Slash = 0 then "" else Prefix (Prefix'First .. Slash));
      --  Where the session was started, below the project's top: what is
      --  typed is from there, as the commands take it.
      Below  : constant String := Model_Runner.CLI.Project_Commands.Started_Below;
      Where  : constant String :=
        (if Below /= "" and then Ada.Directories.Exists (Below & "/" & (if Dir = "" then "." else Dir))
           and then not (Dir /= "" and then Ada.Directories.Exists (Dir))
         then Below & "/" & (if Dir = "" then "." else Dir)
         elsif Dir = "" then "." else Dir);
      Search : Ada.Directories.Search_Type;
      Found  : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Where) then
         return Result;
      end if;
      Ada.Directories.Start_Search (Search, Where, "");
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found);
         declare
            Simple : constant String := Ada.Directories.Simple_Name (Found);
         begin
            if Simple not in "." | ".." and then (Simple (Simple'First) /= '.' or else Prefix'Length > Dir'Length)
            then
               Result.Append (Dir & Simple
                              & (if Ada.Directories."=" (Ada.Directories.Kind (Found), Ada.Directories.Directory)
                                 then "/" else ""));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      return Result;
   exception
      when others =>
         return Result;
   end Paths;

   --  Whether a template is only a part others include: standalone = false.
   function Is_Part (Path : String) return Boolean is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Ada.Strings.Fixed.Index (Line, "standalone") = Line'First
              and then Ada.Strings.Fixed.Index (Line, "false") > 0
            then
               Ada.Text_IO.Close (File);
               return True;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return False;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return False;
   end Is_Part;

   function Candidates (Before : String) return Names.Vector is
      Words   : constant Names.Vector := Words_Of (Before);
      --  The word being completed: the last, or a new one after a space.
      Fresh   : constant Boolean := Before = "" or else Before (Before'Last) = ' ';
      Current : constant String := (if Fresh or else Words.Is_Empty then "" else Words.Last_Element);
      Position : constant Positive := Natural (Words.Length) + (if Fresh then 1 else 0);
      Command : constant String :=
        (if Words.Is_Empty then "" else Ada.Characters.Handling.To_Lower (Words.First_Element));
      Action  : constant String := (if Natural (Words.Length) >= 2 then Words (2) else "");
      Offered : Names.Vector;
      Result  : Names.Vector;

      procedure Offer (Word : String) is
      begin
         if not Offered.Contains (Word) then
            Offered.Append (Word);
         end if;
      end Offer;

      procedure Offer_All (Listed : Names.Vector) is
      begin
         for One of Listed loop
            Offer (One);
         end loop;
      end Offer_All;

      procedure Offer_Words (Text : String) is
      begin
         Offer_All (Words_Of (Text));
      end Offer_Words;

      --  What the project holds, where there is one here.
      procedure From_Project is
         Store : S.Store;
         Read  : E.Error_Info;

         function Register (Prefix : String) return Nt.Intent_Kind
         is (if Prefix = "/req" then Nt.Requirement elsif Prefix = "/spec" then Nt.Specification
             else Nt.Decision);

         procedure Settings is
            package Pm renames Model_Runner.Framework.Permissions;
            Config : R.Item;
            Got    : E.Error_Info;
            Before : constant Natural := Natural (Offered.Length);
         begin
            Offer_All (Model_Runner.Framework.Configurations.Known_Names);
            Model_Runner.Framework.Configurations.Read (Store, Config, Got);
            if E.Is_Ok (Got) then
               for Index in 1 .. R.Field_Count (Config) loop
                  if (for some Prefix of Names.Vector'(["scalar.", "set.", "list.", "map.", "profile."]) =>
                        Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), Prefix) = 1)
                  then
                     Offer (R.Field_Name (Config, Index));
                  end if;
               end loop;
            end if;
            --  Those there may be, set or not: every level's capability,
            --  and every kind's own limits and profile.
            Offer ("map.permission.project");
            Offer ("map.model.default");
            for One in Pm.Capability loop
               Offer ("map.permission.project." & Pm.Word (One));
            end loop;
            for Kind of Tk.Kinds (Store) loop
               Offer ("map.permission.kind." & Kind);
               for One in Pm.Capability loop
                  Offer ("map.permission.kind." & Kind & "." & Pm.Word (One));
               end loop;
               for Limit of Names.Vector'
                 (["max_seconds", "max_tool_calls", "max_steps", "token_budget", "profile", "coordination",
                   "isolation"])
               loop
                  Offer ("scalar.task." & Limit & "." & Kind);
               end loop;
            end loop;
            --  Typed without its kind -- work.isolation -- as the commands
            --  take it: offered so too.
            if Current /= ""
              and then not (for some Prefix of Names.Vector'(["scalar.", "set.", "list.", "map."]) =>
                              Prefix'Length <= Current'Length
                              and then Current (Current'First .. Current'First + Prefix'Length - 1) = Prefix)
            then
               for Index in Before + 1 .. Natural (Offered.Length) loop
                  declare
                     Name : constant String := Offered (Index);
                     Dot  : constant Natural := Ada.Strings.Fixed.Index (Name, ".");
                  begin
                     if Dot > 0 and then Name (Name'First .. Dot) in "scalar." | "set." | "list." then
                        Offer (Name (Dot + 1 .. Name'Last));
                     end if;
                  end;
               end loop;
            end if;
         end Settings;

         procedure Capabilities is
         begin
            for One in Model_Runner.Framework.Permissions.Capability loop
               Offer (Model_Runner.Framework.Permissions.Word (One));
            end loop;
         end Capabilities;
      begin
         if not S.Is_Initialized (Ada.Directories.Current_Directory) then
            return;
         end if;
         S.Open_To_Read (Store, Ada.Directories.Current_Directory, Read);
         if E.Is_Error (Read) then
            return;
         end if;
         --  A setting as NAME=: its values where it has a few.
         if Ada.Strings.Fixed.Index (Current, "kind=") = Current'First then
            for Kind of Tk.Kinds (Store) loop
               Offer ("kind=" & Kind);
            end loop;
         elsif Ada.Strings.Fixed.Index (Current, "state=") = Current'First then
            Offer_Words ("state=candidate state=accepted state=ready state=waiting state=refused state=running"
                         & " state=verification state=blocked state=stopped state=failed state=complete"
                         & " state=cancelled state=rejected");
         elsif Command = "/task" and then Position = 3 then
            if Action = "kept" then
               Offer_Words ("list diff restore drop");
            elsif Action in "list" | "plan" | "new" then
               Offer_Words ("kind= component= state= requirement=");
            else
               Offer_All (Tk.List (Store));
               if Action in "accept" | "reject" | "complete" | "verify" | "integrate" then
                  Offer ("all");
               end if;
            end if;
         elsif Command = "/task" and then Position = 4 then
            if Action = "kept" then
               Offer_All (Model_Runner.Framework.Workspaces.Kept_Copies (Store));
               if Words (3) = "drop" then
                  Offer ("all");
               end if;
            elsif Action in "grant" | "withhold" then
               Capabilities;
            elsif Action = "link" then
               Offer_All (Nt.List (Store, Nt.Requirement));
            elsif Action = "depend" then
               Offer_All (Tk.List (Store));
            elsif Action = "move" then
               Offer_Words ("accepted blocked cancelled");
            elsif Action = "edit" then
               Offer_Words ("title= kind= component= requirements= notes= permissions= depends_on= parent=");
            end if;
         elsif Command = "/task" and then Position = 5 and then Action = "depend" then
            Offer ("remove");
         elsif Command in "/req" | "/spec" | "/decision" and then Position = 3 then
            --  Accepting or rejecting is of what waits: the candidates.
            Offer_All (if Action in "accept" | "reject" then Nt.List (Store, Register (Command), "candidate")
                       else Nt.List (Store, Register (Command)));
            if Action in "accept" | "reject" | "obsolete" | "verify" then
               Offer ("all");
            end if;
         elsif Command in "/req" | "/spec" | "/decision" and then Position = 4 then
            if Action in "link" | "unlink" then
               Offer_Words ("dependency component implementation task test verification");
            elsif Action = "govern" then
               Settings;
            elsif Action = "supersede" then
               Offer_All (Nt.List (Store, Register (Command)));
            elsif Action = "revise" then
               Offer_Words ("from-document title= text= criteria=");
            end if;
         elsif Command in "/req" | "/spec" | "/decision" and then Position = 5 and then Action in "link" | "unlink"
         then
            if Words (4) = "task" then
               Offer_All (Tk.List (Store));
            elsif Words (4) = "dependency" then
               Offer_All (Nt.List (Store, Register (Command)));
            elsif Words (4) = "component" then
               Offer_All (Tk.Components (Store));
            else
               Offer_All (Paths (Current));
            end if;
         elsif Command in "/accept" | "/reject" and then Position = 2 then
            Offer ("all");
            Offer_All (Tk.List (Store, "candidate"));
            for Which of Model_Runner.CLI.Intents.Pending (Store) loop
               Offer (Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last));
            end loop;
         elsif Command = "/work" and then Position >= 2 then
            --  Only those it would start: ready.
            for Id of Tk.List (Store, "accepted") loop
               if Tk.Ready (Store, Id).Ready then
                  Offer (Id);
               end if;
            end loop;
            Offer_Words ("model= steps= profile=");
            if Position = 2 then
               Offer ("all");
            end if;
         elsif Command = "/cancel" and then Position = 2 then
            for Id of Tk.List (Store) loop
               if Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected" then
                  Offer (Id);
               end if;
            end loop;
         elsif Command = "/result" and then Position = 2 then
            for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
               Offer (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                      then Name (Name'First .. Name'Last - 4) else Name);
            end loop;
         elsif Command = "/result" and then Position = 3 and then Action = "restore" then
            --  Only those dismissed come back.
            Offer ("all");
            Offer_All (Model_Runner.CLI.Project_Commands.Dismissed_Issues (Store));
         elsif Command = "/result" and then Position >= 3 and then Action = "dismiss" then
            Offer ("all");
            Offer_All (Model_Runner.CLI.Project_Commands.Open_Issues (Store));
         elsif Command = "/config" and then Position = 2 then
            Settings;
            Capabilities;
         elsif Command = "/reconfigure" and then Position >= 2 then
            --  What a set holds, to take out; a path, to add to one of paths.
            if Action = "remove" and then Position >= 4 then
               declare
                  Config : R.Item;
                  Got    : E.Error_Info;
               begin
                  Model_Runner.Framework.Configurations.Read (Store, Config, Got);
                  if E.Is_Ok (Got) then
                     Offer_All (Model_Runner.Framework.Lines_Of
                                  (Ada.Strings.Fixed.Translate
                                     (R.Get (Config, Words (3)) & ASCII.LF & R.Get (Config, "set." & Words (3)),
                                      Ada.Strings.Maps.To_Mapping (", ", ASCII.LF & ASCII.LF))));
                  end if;
               end;
            elsif Action = "add" and then Position >= 4 then
               Offer_All (Paths (Current));
            elsif Action in "add" | "remove" and then Position = 3 then
               for Name of Model_Runner.Framework.Configurations.Known_Names loop
                  if Ada.Strings.Fixed.Index (Name, "set.") = 1 or else Ada.Strings.Fixed.Index (Name, "list.") = 1
                  then
                     Offer (Name);
                  end if;
               end loop;
            elsif Action not in "add" | "remove" then
               declare
                  Before_Settings : constant Natural := Natural (Offered.Length);
               begin
                  Settings;
                  --  A setting is given its value after =.
                  for Index in Before_Settings + 1 .. Natural (Offered.Length) loop
                     Offered.Replace_Element (Index, String'(Offered (Index)) & "=");
                  end loop;
               end;
            end if;
         elsif Command = "/instruct" and then Position = 3 and then Action = "withdraw" then
            for Line of Model_Runner.Framework.Authority.Standing_Instructions (Store) loop
               Offer (Line (Line'First .. Ada.Strings.Fixed.Index (Line & ":", ":") - 1));
            end loop;
         elsif Command = "/check" and then Position = 2 then
            Offer_All (Nt.List (Store, Nt.Requirement));
         elsif Command = "/trace" and then Position = 2 then
            Offer_All (Nt.List (Store, Nt.Requirement));
            Offer_All (Nt.List (Store, Nt.Specification));
            Offer_All (Nt.List (Store, Nt.Decision));
            Offer_All (Tk.List (Store));
            Offer_All (Paths (Current));
         end if;
         S.Close (Store);
      exception
         when others =>
            S.Close (Store);
      end From_Project;
   begin
      if Position = 1 then
         --  The command itself.
         for Kind in Model_Runner.CLI.Interactive.Command_Kind loop
            if Model_Runner.CLI.Interactive.Command_Word (Kind) /= "" then
               Offer (Model_Runner.CLI.Interactive.Command_Word (Kind));
            end if;
         end loop;
         Offer_Words (Project_Commands);
      elsif Command = "/help" and then Position = 2 then
         for Kind in Model_Runner.CLI.Interactive.Command_Kind loop
            declare
               Word : constant String := Model_Runner.CLI.Interactive.Command_Word (Kind);
            begin
               if Word'Length > 1 then
                  Offer (Word (Word'First + 1 .. Word'Last));
               end if;
            end;
         end loop;
         for Word of Words_Of (Project_Commands) loop
            Offer (Word (Word'First + 1 .. Word'Last));
         end loop;
         Offer ("project");
      elsif Command = "/init" and then Position = 2 then
         declare
            Search : Ada.Directories.Search_Type;
            Found  : Ada.Directories.Directory_Entry_Type;
            Where  : constant String := Model_Runner.Platform.Installed_Templates_Directory;
         begin
            if Ada.Directories.Exists (Where) then
               Ada.Directories.Start_Search (Search, Where, "*.template");
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  --  A kind of project, not a part others include.
                  if not Is_Part (Ada.Directories.Full_Name (Found)) then
                     Offer (Ada.Directories.Base_Name (Ada.Directories.Simple_Name (Found)));
                  end if;
               end loop;
               Ada.Directories.End_Search (Search);
            end if;
         exception
            when others =>
               null;
         end;
      elsif Position = 2 and then Actions_Of (Command) /= "" then
         Offer_Words (Actions_Of (Command));
         From_Project;
      elsif Command in "/refs" | "/sym" | "/deps" | "/users" | "/impact" | "/tree" | "/bootstrap" | "/save"
                     | "/load" | "/image" | "/video"
      then
         Offer_All (Paths (Current));
      else
         From_Project;
      end if;
      --  Those the word typed begins, in order.
      for One of Offered loop
         if One'Length >= Current'Length and then One (One'First .. One'First + Current'Length - 1) = Current then
            Result.Append (One);
         end if;
      end loop;
      Sorting.Sort (Result);
      return Result;
   end Candidates;

end Model_Runner.CLI.Completion;
