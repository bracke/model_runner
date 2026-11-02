with Model_Runner.Text;

package body Model_Runner.CLI.Speech_Input is

   package S renames Model_Runner.Speech;
   package E renames Model_Runner.Errors;

   use Ada.Strings.Unbounded;
   use type S.Recognizer_Access;

   procedure Open (Item : in out Input; From : Model_Runner.CLI.Options.Command) is
      Model : constant String := Model_Runner.Text.To_String (From.Speech_Model_Path);
   begin
      Close (Item);
      if Model = "" or else not From.Speech_Enabled then
         return;
      end if;
      Item.Owner := S.Create
        ((Model_Path     => To_Unbounded_String (Model),
          Language       => To_Unbounded_String (Model_Runner.Text.To_String (From.Speech_Language)),
          Source         => To_Unbounded_String (Model_Runner.Text.To_String (From.Speech_Device)),
          Max_Seconds    => Positive'Max (1, From.Speech_Max_Seconds),
          Keep_Loaded    => From.Speech_Keep_Loaded,
          Initial_Prompt => To_Unbounded_String (Model_Runner.Text.To_String (From.Speech_Initial_Prompt)),
          Workers        => 0,
          Played         => null));
   end Open;

   procedure Close (Item : in out Input) is
   begin
      S.Shutdown (Item.Owner);
   end Close;

   overriding procedure Finalize (Item : in out Input) is
   begin
      Close (Item);
   end Finalize;

   function Is_Enabled (Item : Input) return Boolean is (Item.Owner /= null);

   overriding procedure Begin_Dictation (Item : in out Input; Status : out E.Error_Info) is
   begin
      if Item.Owner = null then
         Status := E.Make (E.Lifecycle_Speech_Disabled);
         return;
      end if;
      S.Start (Item.Owner.all, Status);
   end Begin_Dictation;

   overriding function Seconds (Item : Input) return Natural is
     (if Item.Owner = null then 0 else Natural (Float'Floor (Float (S.Recorded_Seconds (Item.Owner.all)))));

   overriding function Ended_Itself (Item : Input) return Boolean is
     (Item.Owner /= null and then S.Recording_Ended (Item.Owner.all));

   overriding procedure End_Dictation (Item : in out Input) is
      Ignored : E.Error_Info;
   begin
      if Item.Owner /= null then
         S.Finish (Item.Owner.all, Ignored);
      end if;
   end End_Dictation;

   overriding procedure Abandon (Item : in out Input) is
   begin
      if Item.Owner /= null then
         S.Cancel (Item.Owner.all);
      end if;
   end Abandon;

   overriding function Is_Done (Item : Input) return Boolean is
     (Item.Owner = null or else S.Has_Result (Item.Owner.all));

   overriding procedure Take
     (Item          : in out Input;
      Text          : out Unbounded_String;
      Status        : out E.Error_Info;
      Limit_Reached : out Boolean) is
   begin
      Text := Null_Unbounded_String;
      Limit_Reached := False;
      if Item.Owner = null then
         Status := E.Make (E.Lifecycle_Speech_Disabled);
         return;
      end if;
      S.Take (Item.Owner.all, Text, Status, Limit_Reached);
   end Take;

end Model_Runner.CLI.Speech_Input;
