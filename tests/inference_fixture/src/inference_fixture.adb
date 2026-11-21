with Ada.Command_Line;

with Tiny_Model;

procedure Inference_Fixture is
begin
   if Ada.Command_Line.Argument_Count /= 1 then
      raise Program_Error with "usage: inference_fixture OUTPUT.gguf";
   end if;
   Tiny_Model.Write (Ada.Command_Line.Argument (1), Byte_Pair => True);
end Inference_Fixture;
