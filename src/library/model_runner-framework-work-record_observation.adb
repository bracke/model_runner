with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Schemas;

separate (Model_Runner.Framework.Work)
procedure Record_Observation
  (Host      : in out Child_Host;
   Arguments : String;
   Report    : out Ada.Strings.Unbounded.Unbounded_String;
   Status    : out Model_Runner.Errors.Error_Info)
is
   Said   : Observations.Draft;
   From   : Observations.Origin;
   Found  : Boolean;
   Change : Stores.Transaction;
   Id     : Unbounded_String;
   Fresh  : Boolean;
   Wrong  : Unbounded_String;

   --  A list argument, every item kept; one not given as a list is said.
   procedure Take (Key : String; Into : in out Name_Lists.Vector) is
      Items       : Model_Runner.Tools.Schemas.Choice_Lists.Vector;
      Given       : Boolean;
      Well_Formed : Boolean;
   begin
      Model_Runner.Tools.Builtin.Text_List_Argument (Arguments, Key, Items, Given, Well_Formed);
      if not Well_Formed and then Length (Wrong) = 0 then
         Wrong := To_Unbounded_String (Key & " is a list, as [""src/a.adb""]");
      end if;
      for One of Items loop
         Into.Append (One);
      end loop;
   end Take;
begin
   Report := Null_Unbounded_String;
   Observations.Kind_Of
     (Model_Runner.Tools.Builtin.Text_Argument (Arguments, "kind", Found), Said.Kind, Found);
   if not Found then
      Status := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Status, "name", "kind");
      E.Add_Text (Status, "value", Model_Runner.Tools.Builtin.Text_Argument (Arguments, "kind", Found));
      E.Add_Text (Status, "detail", "not a kind of observation");
      Report := To_Unbounded_String
        ("error: kind is one of finding, experiment, failure_pattern, environment_constraint,"
         & " tool_behavior, implementation_note");
      return;
   end if;
   Said.Summary := To_Unbounded_String (Model_Runner.Tools.Builtin.Text_Argument (Arguments, "summary", Found));
   Take ("files", Said.Files);
   Take ("symbols", Said.Symbols);
   Take ("evidence", Said.Evidence);
   if Length (Wrong) > 0 then
      Status := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Status, "name", "record_observation");
      E.Add_Text (Status, "value", "its arguments");
      E.Add_Text (Status, "detail", To_String (Wrong));
      Report := "error: " & Wrong;
      return;
   end if;

   --  Whose it is, as the host knows it: never the call's to say.
   From :=
     (Producer   => Observations.Agent_Producer,
      Task_Id    => Host.Task_Id,
      Generation => To_Unbounded_String (Generation_Of (Host.Item.all, To_String (Host.Task_Id))),
      Agent      => To_Unbounded_String (Current (Host)),
      Parent     => (if Natural (Host.Open.Length) > 1
                     then To_Unbounded_String (Host.Open (Natural (Host.Open.Length) - 1))
                     else Null_Unbounded_String),
      Invocation => (if Host.Calls.Is_Empty then Null_Unbounded_String
                     else To_Unbounded_String (Host.Calls.Last_Element)),
      Tree       => (if Host.Apart then Host.Tree else Null_Unbounded_String));
   Observations.Record_Observation (Host.Item.all, Change, Said, From, Id, Fresh, Status);
   if E.Is_Ok (Status) then
      Stores.Commit (Host.Item.all, Change, Status);
   end if;
   if E.Is_Error (Status) then
      Report := To_Unbounded_String
        ("error: not kept: "
         & (if E.Text_Of (Status, "detail") /= "" then E.Text_Of (Status, "detail")
            elsif E.Text_Of (Status, "name") /= "" then E.Text_Of (Status, "name") & " is not there"
            else "the project's state could not keep it"));
      return;
   end if;
   Report := To_Unbounded_String
     ((if Fresh then "kept as " else "seen before; counted again on ") & To_String (Id)
      & " -- an observation of " & To_String (Host.Task_Id)
      & ", told to later work on it; it changes nothing about the task");
end Record_Observation;
