with Ada.Command_Line;

with Tiny_Model;

procedure Inference_Fixture is
begin
   if Ada.Command_Line.Argument_Count not in 1 | 2 then
      raise Program_Error with "usage: inference_fixture OUTPUT.gguf [ADAPTER.gguf]";
   end if;
   Tiny_Model.Write (Ada.Command_Line.Argument (1), Byte_Pair => True);
   if Ada.Command_Line.Argument_Count = 2 then
      Tiny_Model.Write_Adapter (Ada.Command_Line.Argument (2));
   end if;
end Inference_Fixture;
