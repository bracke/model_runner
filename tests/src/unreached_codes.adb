package body Unreached_Codes is

   package E renames Model_Runner.Errors;

   ------------------
   -- Is_Unreached --
   ------------------

   function Is_Unreached (Code : E.Error_Code) return Boolean is
   begin
      --  Named rather than listed as text, so a code that is renamed or
      --  removed fails to compile here instead of quietly falling off.
      case Code is
         --  Reached only from a host call failing. The environment cannot
         --  be made to refuse a read from inside the suite without breaking
         --  the process it runs in.
         when E.CLI_Invalid_Environment_Value

         --  A prompt file larger than the input bound. Writing one costs
         --  more disk and time than the refusal is worth checking that way;
         --  the bound itself is checked where it is applied.
            | E.IO_Input_Too_Large

         --  Reached when a size computation would overflow while reading a
         --  container. The fuzzing campaign is what walks those paths, and
         --  it reports the outcome by class rather than by code.
            | E.GGUF_Arithmetic_Overflow

         --  A tensor whose format the architecture cannot use, as opposed to
         --  one the container rejects. Every format the fixture writer can
         --  write is one this architecture accepts, so reaching it needs a
         --  container carrying a format the reader knows and the model does
         --  not -- which is a fixture nobody has written.
            | E.Arch_Invalid_Tensor_Format

         --  A worker that failed, which guards a request the command layer
         --  clamps before it arrives. The clamps are tested; what is not is
         --  the backend refusing a caller that ignored them, and no caller
         --  here can.
         --
         --  Two others came off this list when a backend arrived that read
         --  three formats out of fifteen, and both went back on when the
         --  shader learnt the other twelve. That is the shape of every entry
         --  here: a code is unreachable until some part of the program can
         --  be asked to produce it, and it stops being reachable again when
         --  that part stops being able to. Worth noticing in both
         --  directions, which is why this list is checked both ways.
            | E.Backend_Worker_Failed

         --  A model in a format the chosen backend cannot read, refused
         --  while it loads. The device was the one backend that read some
         --  formats and not others, and now it reads all fifteen -- so
         --  reaching this needs a model in a format the program decodes and
         --  a backend that does not, and there is no such pair. The check is
         --  still written, because the next format added to the program will
         --  make one until the shader is taught it too.
            | E.Backend_Unsupported_Format

         --  The same refusal at the level of a single product rather than a
         --  model, and unreachable for the same reason. A view cannot be
         --  built in a format the program does not decode, and every format
         --  it decodes the shader now decodes as well.
            | E.Backend_Capability_Missing

         --  A distribution that is not one. Sampling refuses non-finite
         --  logits before it normalizes, so the state this names is one the
         --  arithmetic would have to produce on its own.
            | E.Sampling_Invalid_Distribution

         --  A softmax that produced something that is not a number. The
         --  weights would have to be large enough for a row product to
         --  overflow binary32, which no fixture here writes and which a
         --  fixture written for it would be testing the arithmetic's
         --  overflow rather than the refusal.
            | E.Tensor_Non_Finite_Value

         --  The last resort. Raised where an exception reaches a handler
         --  that has nothing better to say, and a test that reached it would
         --  be a test that had already found a defect.
            | E.Internal_Unexpected_Exception
         =>
            return True;

         when others =>
            return False;
      end case;
   end Is_Unreached;

   -----------
   -- Count --
   -----------

   function Count return Natural is
      Total : Natural := 0;
   begin
      for Code in E.Error_Code loop
         if Is_Unreached (Code) then
            Total := Total + 1;
         end if;
      end loop;

      return Total;
   end Count;

end Unreached_Codes;
