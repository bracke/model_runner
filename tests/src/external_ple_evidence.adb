with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Shards;

package body External_PLE_Evidence is

   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package Shards renames Model_Runner.GGUF.Shards;

   procedure Check
     (Path   : String;
      State  : out Backbone_State;
      Status : out E.Error_Info)
   is
      Source    : Shards.Shard_Set;
      Container : Containers.Container;
   begin
      State := Backbone_Unreadable;
      Shards.Open_Model (Source, Container, Path, Status => Status);
      if E.Is_Error (Status) then
         Containers.Close (Container);
         Shards.Close (Source);
         return;
      end if;

      State :=
        (if Containers.Find_Tensor
              (Container, "per_layer_token_embd.weight") = 0
         then External_PLE_Required
         else PLE_Still_In_Backbone);
      Containers.Close (Container);
      Shards.Close (Source);
   exception
      when others =>
         Containers.Close (Container);
         Shards.Close (Source);
         raise;
   end Check;

end External_PLE_Evidence;
