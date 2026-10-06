separate (Model_Runner.Framework.Work)
function Unable_Reason (Item : Stores.Store; Task_Id : String) return String is
   View : Records.Item;
   Read : E.Error_Info;
begin
   Tasks.Effective (Item, Task_Id, View, Read);
   if E.Is_Error (Read) then
      return "";
   end if;
   declare
      Allowed : constant Permissions.Permission_Set :=
        Permissions.Effective (Item, Records.Get (View, "definition.kind"), "worker",
                               Task_Level => Records.Get (View, "definition.permissions"));
      Writes  : constant Boolean :=
        Ada.Strings.Fixed.Index (Records.Get (View, "gates"), "implementation_present") > 0;
      Homes   : constant Name_Lists.Vector :=
        Repository.Component_Roots (Item, Records.Get (View, "definition.component"));
      --  Where its component's files are and it may write none of them.
      Elsewhere : constant Boolean :=
        Writes and then Permissions.Allows (Allowed, Permissions.Write_Source)
        and then not Homes.Is_Empty
        and then not (for some Home of Homes =>
                        Permissions.Allows (Allowed, Permissions.Write_Source,
                                            (if Home'Length > 0 and then Home (Home'Last) = '/'
                                             then Home else Home & "/") & "x"));
      --  The project's files its title or notes name that it may not
      --  write: work on those it could not do.
      function Named_Out_Of_Reach return String is
         Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
         Words   : constant String :=
           Records.Get (View, "definition.title") & " " & Records.Get (View, "definition.notes")
           & " " & Records.Get (View, "definition.question");
         Start   : Natural := Words'First;
         Out_Of  : Unbounded_String;
      begin
         if not Writes then
            return "";
         end if;
         for Index in Words'First .. Words'Last + 1 loop
            if Index > Words'Last or else Words (Index) in ' ' | ',' | ';' | '"' | '(' | ')' then
               declare
                  Word : constant String :=
                    Ada.Strings.Fixed.Trim (Words (Start .. Index - 1), Ada.Strings.Maps.To_Set (".:`'"),
                                            Ada.Strings.Maps.To_Set (".:`'"));
               begin
                  if Ada.Strings.Fixed.Index (Word, "/") > 0
                    and then Ada.Strings.Fixed.Index (Word, "..") = 0
                    and then Word (Word'First) /= '/'
                    and then Ada.Directories.Exists (Hostkit.Fs.Join (Project, Word))
                    and then not Permissions.Allows (Allowed, Permissions.Write_Source, Word)
                    and then not Permissions.Allows (Allowed, Permissions.Write_Specs, Word)
                  then
                     Append (Out_Of, (if Out_Of = Null_Unbounded_String then "" else ", ") & Word);
                  end if;
               exception
                  when others =>
                     null;
               end;
               Start := Index + 1;
            end if;
         end loop;
         return To_String (Out_Of);
      end Named_Out_Of_Reach;
      --  Whether the directory a place would be made in is there.
      function Parent_Exists (Root : String) return Boolean is
         Bare : constant String :=
           (if Root'Length > 1 and then Root (Root'Last) = '/' then Root (Root'First .. Root'Last - 1) else Root);
         Slash : constant Natural := Ada.Strings.Fixed.Index (Bare, "/", Ada.Strings.Backward);
      begin
         return Bare /= ""
           and then (Slash = 0
                     or else Ada.Directories.Exists
                               (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Stores.Root (Item)),
                                                 Bare (Bare'First .. Slash - 1))));
      exception
         when others =>
            return False;
      end Parent_Exists;
      Lacks   : constant String :=
        (if Permissions.Image (Allowed) = "" then "anything"
         --  Specifications alone are writing only for documentation:
         --  an implementation's files are source.
         elsif Writes and then not Permissions.Allows (Allowed, Permissions.Write_Source)
           and then not (Permissions.Allows (Allowed, Permissions.Write_Specs)
                         and then Records.Get (View, "definition.kind") = "documentation")
         then "write a file"
         elsif not Permissions.Allows (Allowed, Permissions.Read_Source) then "read the source"
         elsif Elsewhere then "write where its component's files are"
         --  Roots it may write under, none of them in the project.
         elsif Writes and then Permissions.Allows (Allowed, Permissions.Write_Source)
           and then not Allowed (Permissions.Write_Source).Roots.Is_Empty
           --  One it can make -- docs/ in the project's top -- is a place
           --  all the same: what is above it is there.
           and then (for all Root of Allowed (Permissions.Write_Source).Roots =>
                       not Ada.Directories.Exists
                             (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Stores.Root (Item)), Root))
                       and then not Parent_Exists (Root))
         then "write anywhere there is: no place it may write under is in the project"
         elsif Named_Out_Of_Reach /= "" then "write " & Named_Out_Of_Reach & ", which its task names"
         else "");
   begin
      if Lacks = "" then
         return "";
      end if;
      --  The level that withholds it, and the setting that grants it.
      declare
         Kind   : constant String := Records.Get (View, "definition.kind");
         Config : Records.Item;
         Got    : E.Error_Info;
         Kind_Named : Boolean := False;
         Capability : constant String :=
           (if Lacks = "write a file" or else Ada.Strings.Fixed.Index (Lacks, "write anywhere") = Lacks'First
            then "write_source"
            elsif Lacks in "read the source" | "anything" then "read_source" else "");
         --  The other of reading and writing the source, lacking too: named
         --  in the same hint, so granting the one does not leave it refused.
         Also : constant String :=
           (if Capability = "read_source" and then Writes
              and then not Permissions.Allows (Allowed, Permissions.Write_Source)
            then "write_source"
            elsif Capability = "write_source" and then not Permissions.Allows (Allowed, Permissions.Read_Source)
            then "read_source" else "");
      begin
         Configurations.Read (Item, Config, Got);
         for Index in 1 .. Records.Field_Count (Config) loop
            Kind_Named := Kind_Named
              or else Ada.Strings.Fixed.Index (Records.Field_Name (Config, Index),
                                               "map.permission.kind." & Kind & ".") = 1
              or else Records.Field_Name (Config, Index) = "map.permission.kind." & Kind;
         end loop;
         declare
            --  Which level withholds it: the task's own field only where
            --  its kind would grant it; else the kind, else the project.
            Of_Kind    : constant Permissions.Permission_Set :=
              Permissions.Effective (Item, Kind, "worker", Within_Sandbox => False);
            Of_Project : constant Permissions.Permission_Set :=
              Permissions.Effective (Item, "", "worker", Within_Sandbox => False);
            function Grants (Set : Permissions.Permission_Set) return Boolean
            is (Capability /= ""
                and then (for some One in Permissions.Capability =>
                            Permissions.Word (One) = Capability and then Set (One).Granted));
            --  Without the role an agent works in: what the kind gives.
            Of_Kind_Alone : constant Permissions.Permission_Set :=
              Permissions.Effective (Item, Kind, "", Within_Sandbox => False);
            By_Role : constant Boolean :=
              Grants (Of_Kind_Alone) and then not Grants (Of_Kind)
              and then Ada.Strings.Fixed.Index (Lacks, "write anywhere") = 0;
            Own_Narrows : constant Boolean :=
              Records.Get (View, "definition.permissions") /= "" and then Grants (Of_Kind) and then not By_Role;
            --  The task's own field withholding it as well as a level
            --  above: both said, the task's first, or granting the one
            --  leaves the other.
            function Own_Withholds return Boolean is
               Own    : constant String := Records.Get (View, "definition.permissions");
               Parsed : Permissions.Permission_Set;
               Bad    : E.Error_Info;
            begin
               if Own = "" or else Capability = "" or else Own = "inherit" then
                  return False;
               elsif Permissions.Only_Withholds (Own) then
                  return Ada.Strings.Fixed.Index (Own, "-" & Capability) > 0;
               end if;
               Permissions.Restriction (Own, Parsed, Bad);
               return E.Is_Ok (Bad) and then not Grants (Parsed);
            end Own_Withholds;
            Own_Too : constant Boolean := not Own_Narrows and then Own_Withholds;
            Level : constant String :=
              (if By_Role then "role.worker"
               elsif Kind_Named and then Grants (Of_Project) then "kind." & Kind else "project");
         begin
            return (if Lacks = "anything" then "it may do nothing at all" else "it would not be let " & Lacks)
              & (if Lacks = "write a file" then ", which its gate implementation_present needs" else "")
              & (if Own_Too
                 then "; its own permissions withhold " & Capability & " -- /task grant " & Task_Id & " "
                      & Capability & " gives it back"
                 else "")
              & (if Capability = "" or else Permissions."/=" (Permissions.Sandbox, Permissions.Unrestricted)
                   or else Own_Narrows
                 then ""
                 elsif Also /= ""
                 then "; " & Level & " withholds " & Capability & " and " & Also & " -- /reconfigure"
                      & " map.permission." & Level & "." & Capability & "=on map.permission." & Level & "."
                      & Also & "=on grants them"
                 --  The role's own withholding is taken away, not granted over.
                 elsif By_Role
                 then "; " & Level & " withholds " & Capability & " -- /reconfigure map.permission."
                      & Level & "." & Capability & "=inherit gives it back"
                 else "; " & Level & " withholds " & Capability & " -- /reconfigure map.permission."
                      & Level & "." & Capability & "=on grants it")
              & (if Elsewhere then " (" & Comma_Separated (Homes) & ")" else "")
              & (if Permissions."/=" (Permissions.Sandbox, Permissions.Unrestricted)
                 then "; " & Permissions.Sandbox_Source & " confines it -- /sandbox off lifts that"
                 else "")
              & (if Own_Narrows
                 then "; its own permissions narrow it -- /task grant " & Task_Id & " " & Capability
                      & " gives it back, or /task edit " & Task_Id & " permissions=inherit takes its kind's"
                 else "");
         end;
      end;
   end;
end Unable_Reason;
