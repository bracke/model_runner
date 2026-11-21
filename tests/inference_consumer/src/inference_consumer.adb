with Ada.Command_Line;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Inference;

procedure Inference_Consumer is
   package E renames Model_Runner.Errors;
   package I renames Model_Runner.Inference;

   use type I.Completion_State;

   Item    : I.Session;
   Status  : E.Error_Info;
   Outcome : I.Completion;
   Opening : constant I.Open_Options :=
     (Workers => 4,
      others => <>);
   Options : constant I.Completion_Options :=
     (Maximum_Tokens => 4,
      Maximum_Output_Bytes => 16,
      others => <>);

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;
begin
   Require
     (Model_Runner.Framework.Directory_Name
        (Model_Runner.Framework.Project_Area) = "project",
      "the framework imported beside inference is not operational");
   Require
     (Ada.Command_Line.Argument_Count = 1,
      "usage: inference_consumer MODEL.gguf");
   I.Open (Item, Ada.Command_Line.Argument (1), Opening, Status);
   Require (E.Is_Ok (Status), "the embedded inference session did not open");
   Require (I.Is_Open (Item), "the opened embedded session says it is closed");

   I.Complete (Item, "ab", "{""const"":12}", Options, Outcome);
   Require
     (Outcome.State = I.Completion_Ready,
      "embedded completion failed with " & I.Completion_State'Image (Outcome.State));
   Require
     (Ada.Strings.Unbounded.Length (Outcome.Text) <= Options.Maximum_Output_Bytes,
      "embedded completion exceeded its output bound");

   I.Close (Item, Status);
   Require (E.Is_Ok (Status), "the embedded session did not close cleanly");
   Require (not I.Is_Open (Item), "closing the embedded session left it open");
   Ada.Text_IO.Put_Line ("inference consumer: ok");
exception
   when others =>
      I.Close (Item, Status);
      raise;
end Inference_Consumer;
