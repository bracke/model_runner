with Interfaces;

package body Model_Runner.Quantization.Decoders is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.GGUF.Tensor_Type;
   use type Model_Runner.Numerics.Real;

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   --  Elements per k-quant super-block.
   Super : constant := 256;

   --  The sixteen levels a non-linear four-bit quant may take.
   --
   --  Unlike every other format here, a nibble is not a number: it is an
   --  index into this table, and the table is part of the format rather than
   --  of any file. The spacing is fine near zero and coarse away from it,
   --  which is what "non-linear" means and why four bits go further here
   --  than they do in Q4_0. Indexing it is the gather that decides which of
   --  the two compilations of this unit is faster for these two formats.
   Levels : constant array (0 .. 15) of Integer :=
     [-127, -104, -83, -65, -49, -35, -22, -10,
         1,   13,  25,  38,  53,  69,  89, 113];

   --  IQ3_S's grid: 512 entries, each four bytes that are four values.
   --  Transcribed from llama.cpp's iq3s_grid (ggml-common.h).
   IQ3S_Grid : constant array (0 .. 511) of Interfaces.Unsigned_32 :=
     [
      16#01010101#, 16#01010103#, 16#01010105#, 16#0101010B#, 16#0101010F#, 16#01010301#,
      16#01010303#, 16#01010305#, 16#01010309#, 16#0101030D#, 16#01010501#, 16#01010503#,
      16#0101050B#, 16#01010707#, 16#01010901#, 16#01010905#, 16#0101090B#, 16#0101090F#,
      16#01010B03#, 16#01010B07#, 16#01010D01#, 16#01010D05#, 16#01010F03#, 16#01010F09#,
      16#01010F0F#, 16#01030101#, 16#01030103#, 16#01030105#, 16#01030109#, 16#01030301#,
      16#01030303#, 16#0103030B#, 16#01030501#, 16#01030507#, 16#0103050F#, 16#01030703#,
      16#0103070B#, 16#01030909#, 16#01030D03#, 16#01030D0B#, 16#01030F05#, 16#01050101#,
      16#01050103#, 16#0105010B#, 16#0105010F#, 16#01050301#, 16#01050307#, 16#0105030D#,
      16#01050503#, 16#0105050B#, 16#01050701#, 16#01050709#, 16#01050905#, 16#0105090B#,
      16#0105090F#, 16#01050B03#, 16#01050B07#, 16#01050F01#, 16#01050F07#, 16#01070107#,
      16#01070303#, 16#0107030B#, 16#01070501#, 16#01070505#, 16#01070703#, 16#01070707#,
      16#0107070D#, 16#01070909#, 16#01070B01#, 16#01070B05#, 16#01070D0F#, 16#01070F03#,
      16#01070F0B#, 16#01090101#, 16#01090307#, 16#0109030F#, 16#01090503#, 16#01090509#,
      16#01090705#, 16#01090901#, 16#01090907#, 16#01090B03#, 16#01090F01#, 16#010B0105#,
      16#010B0109#, 16#010B0501#, 16#010B0505#, 16#010B050D#, 16#010B0707#, 16#010B0903#,
      16#010B090B#, 16#010B090F#, 16#010B0D0D#, 16#010B0F07#, 16#010D010D#, 16#010D0303#,
      16#010D0307#, 16#010D0703#, 16#010D0B05#, 16#010D0F03#, 16#010F0101#, 16#010F0105#,
      16#010F0109#, 16#010F0501#, 16#010F0505#, 16#010F050D#, 16#010F0707#, 16#010F0B01#,
      16#010F0B09#, 16#03010101#, 16#03010103#, 16#03010105#, 16#03010109#, 16#03010301#,
      16#03010303#, 16#03010307#, 16#0301030B#, 16#0301030F#, 16#03010501#, 16#03010505#,
      16#03010703#, 16#03010709#, 16#0301070D#, 16#03010B09#, 16#03010B0D#, 16#03010D03#,
      16#03010F05#, 16#03030101#, 16#03030103#, 16#03030107#, 16#0303010D#, 16#03030301#,
      16#03030309#, 16#03030503#, 16#03030701#, 16#03030707#, 16#03030903#, 16#03030B01#,
      16#03030B05#, 16#03030F01#, 16#03030F0D#, 16#03050101#, 16#03050305#, 16#0305030B#,
      16#0305030F#, 16#03050501#, 16#03050509#, 16#03050705#, 16#03050901#, 16#03050907#,
      16#03050B0B#, 16#03050D01#, 16#03050F05#, 16#03070103#, 16#03070109#, 16#0307010F#,
      16#03070301#, 16#03070307#, 16#03070503#, 16#0307050F#, 16#03070701#, 16#03070709#,
      16#03070903#, 16#03070D05#, 16#03070F01#, 16#03090107#, 16#0309010B#, 16#03090305#,
      16#03090309#, 16#03090703#, 16#03090707#, 16#03090905#, 16#0309090D#, 16#03090B01#,
      16#03090B09#, 16#030B0103#, 16#030B0301#, 16#030B0307#, 16#030B0503#, 16#030B0701#,
      16#030B0705#, 16#030B0B03#, 16#030D0501#, 16#030D0509#, 16#030D050F#, 16#030D0909#,
      16#030D090D#, 16#030F0103#, 16#030F0107#, 16#030F0301#, 16#030F0305#, 16#030F0503#,
      16#030F070B#, 16#030F0903#, 16#030F0D05#, 16#030F0F01#, 16#05010101#, 16#05010103#,
      16#05010107#, 16#0501010B#, 16#0501010F#, 16#05010301#, 16#05010305#, 16#05010309#,
      16#0501030D#, 16#05010503#, 16#05010507#, 16#0501050F#, 16#05010701#, 16#05010705#,
      16#05010903#, 16#05010907#, 16#0501090B#, 16#05010B01#, 16#05010B05#, 16#05010D0F#,
      16#05010F01#, 16#05010F07#, 16#05010F0B#, 16#05030101#, 16#05030105#, 16#05030301#,
      16#05030307#, 16#0503030F#, 16#05030505#, 16#0503050B#, 16#05030703#, 16#05030709#,
      16#05030905#, 16#05030B03#, 16#05050103#, 16#05050109#, 16#0505010F#, 16#05050503#,
      16#05050507#, 16#05050701#, 16#0505070F#, 16#05050903#, 16#05050B07#, 16#05050B0F#,
      16#05050F03#, 16#05050F09#, 16#05070101#, 16#05070105#, 16#0507010B#, 16#05070303#,
      16#05070505#, 16#05070509#, 16#05070703#, 16#05070707#, 16#05070905#, 16#05070B01#,
      16#05070D0D#, 16#05090103#, 16#0509010F#, 16#05090501#, 16#05090507#, 16#05090705#,
      16#0509070B#, 16#05090903#, 16#05090F05#, 16#05090F0B#, 16#050B0109#, 16#050B0303#,
      16#050B0505#, 16#050B070F#, 16#050B0901#, 16#050B0B07#, 16#050B0F01#, 16#050D0101#,
      16#050D0105#, 16#050D010F#, 16#050D0503#, 16#050D0B0B#, 16#050D0D03#, 16#050F010B#,
      16#050F0303#, 16#050F050D#, 16#050F0701#, 16#050F0907#, 16#050F0B01#, 16#07010105#,
      16#07010303#, 16#07010307#, 16#0701030B#, 16#0701030F#, 16#07010505#, 16#07010703#,
      16#07010707#, 16#0701070B#, 16#07010905#, 16#07010909#, 16#0701090F#, 16#07010B03#,
      16#07010D07#, 16#07010F03#, 16#07030103#, 16#07030107#, 16#0703010B#, 16#07030309#,
      16#07030503#, 16#07030507#, 16#07030901#, 16#07030D01#, 16#07030F05#, 16#07030F0D#,
      16#07050101#, 16#07050305#, 16#07050501#, 16#07050705#, 16#07050709#, 16#07050B01#,
      16#07070103#, 16#07070301#, 16#07070309#, 16#07070503#, 16#07070507#, 16#0707050F#,
      16#07070701#, 16#07070903#, 16#07070907#, 16#0707090F#, 16#07070B0B#, 16#07070F07#,
      16#07090107#, 16#07090303#, 16#0709030D#, 16#07090505#, 16#07090703#, 16#07090B05#,
      16#07090D01#, 16#07090D09#, 16#070B0103#, 16#070B0301#, 16#070B0305#, 16#070B050B#,
      16#070B0705#, 16#070B0909#, 16#070B0B0D#, 16#070B0F07#, 16#070D030D#, 16#070D0903#,
      16#070F0103#, 16#070F0107#, 16#070F0501#, 16#070F0505#, 16#070F070B#, 16#09010101#,
      16#09010109#, 16#09010305#, 16#09010501#, 16#09010509#, 16#0901050F#, 16#09010705#,
      16#09010903#, 16#09010B01#, 16#09010F01#, 16#09030105#, 16#0903010F#, 16#09030303#,
      16#09030307#, 16#09030505#, 16#09030701#, 16#0903070B#, 16#09030907#, 16#09030B03#,
      16#09030B0B#, 16#09050103#, 16#09050107#, 16#09050301#, 16#0905030B#, 16#09050503#,
      16#09050707#, 16#09050901#, 16#09050B0F#, 16#09050D05#, 16#09050F01#, 16#09070109#,
      16#09070303#, 16#09070307#, 16#09070501#, 16#09070505#, 16#09070703#, 16#0907070B#,
      16#09090101#, 16#09090105#, 16#09090509#, 16#0909070F#, 16#09090901#, 16#09090F03#,
      16#090B010B#, 16#090B010F#, 16#090B0503#, 16#090B0D05#, 16#090D0307#, 16#090D0709#,
      16#090D0D01#, 16#090F0301#, 16#090F030B#, 16#090F0701#, 16#090F0907#, 16#090F0B03#,
      16#0B010105#, 16#0B010301#, 16#0B010309#, 16#0B010505#, 16#0B010901#, 16#0B010909#,
      16#0B01090F#, 16#0B010B05#, 16#0B010D0D#, 16#0B010F09#, 16#0B030103#, 16#0B030107#,
      16#0B03010B#, 16#0B030305#, 16#0B030503#, 16#0B030705#, 16#0B030F05#, 16#0B050101#,
      16#0B050303#, 16#0B050507#, 16#0B050701#, 16#0B05070D#, 16#0B050B07#, 16#0B070105#,
      16#0B07010F#, 16#0B070301#, 16#0B07050F#, 16#0B070909#, 16#0B070B03#, 16#0B070D0B#,
      16#0B070F07#, 16#0B090103#, 16#0B090109#, 16#0B090501#, 16#0B090705#, 16#0B09090D#,
      16#0B0B0305#, 16#0B0B050D#, 16#0B0B0B03#, 16#0B0B0B07#, 16#0B0D0905#, 16#0B0F0105#,
      16#0B0F0109#, 16#0B0F0505#, 16#0D010303#, 16#0D010307#, 16#0D01030B#, 16#0D010703#,
      16#0D010707#, 16#0D010D01#, 16#0D030101#, 16#0D030501#, 16#0D03050F#, 16#0D030D09#,
      16#0D050305#, 16#0D050709#, 16#0D050905#, 16#0D050B0B#, 16#0D050D05#, 16#0D050F01#,
      16#0D070101#, 16#0D070309#, 16#0D070503#, 16#0D070901#, 16#0D09050B#, 16#0D090907#,
      16#0D090D05#, 16#0D0B0101#, 16#0D0B0107#, 16#0D0B0709#, 16#0D0B0D01#, 16#0D0D010B#,
      16#0D0D0901#, 16#0D0F0303#, 16#0D0F0307#, 16#0F010101#, 16#0F010109#, 16#0F01010F#,
      16#0F010501#, 16#0F010505#, 16#0F01070D#, 16#0F010901#, 16#0F010B09#, 16#0F010D05#,
      16#0F030105#, 16#0F030303#, 16#0F030509#, 16#0F030907#, 16#0F03090B#, 16#0F050103#,
      16#0F050109#, 16#0F050301#, 16#0F05030D#, 16#0F050503#, 16#0F050701#, 16#0F050B03#,
      16#0F070105#, 16#0F070705#, 16#0F07070B#, 16#0F070B07#, 16#0F090103#, 16#0F09010B#,
      16#0F090307#, 16#0F090501#, 16#0F090B01#, 16#0F0B0505#, 16#0F0B0905#, 16#0F0D0105#,
      16#0F0D0703#, 16#0F0F0101#];

   --  IQ2_XXS's grid: 256 entries, each a 64-bit number that is eight bytes,
   --  each byte a value. Transcribed from llama.cpp's iq2xxs_grid
   --  (ggml-common.h).
   IQ2XXS_Grid : constant array (0 .. 255) of Interfaces.Unsigned_64 :=
     [
      16#0808080808080808#, 16#080808080808082B#, 16#0808080808081919#, 16#0808080808082B08#,
      16#0808080808082B2B#, 16#0808080808190819#, 16#0808080808191908#, 16#08080808082B0808#,
      16#08080808082B082B#, 16#08080808082B2B08#, 16#08080808082B2B2B#, 16#0808080819080819#,
      16#0808080819081908#, 16#0808080819190808#, 16#0808080819192B08#, 16#08080808192B0819#,
      16#08080808192B1908#, 16#080808082B080808#, 16#080808082B08082B#, 16#080808082B082B2B#,
      16#080808082B2B082B#, 16#0808081908080819#, 16#0808081908081908#, 16#0808081908190808#,
      16#0808081908191919#, 16#0808081919080808#, 16#080808192B081908#, 16#080808192B192B08#,
      16#0808082B08080808#, 16#0808082B0808082B#, 16#0808082B082B082B#, 16#0808082B2B08082B#,
      16#0808190808080819#, 16#0808190808081908#, 16#0808190808190808#, 16#08081908082B0819#,
      16#08081908082B1908#, 16#0808190819080808#, 16#080819081908082B#, 16#0808190819082B08#,
      16#08081908192B0808#, 16#080819082B080819#, 16#080819082B081908#, 16#080819082B190808#,
      16#080819082B2B1908#, 16#0808191908080808#, 16#080819190808082B#, 16#0808191908082B08#,
      16#08081919082B0808#, 16#080819191908192B#, 16#08081919192B2B19#, 16#080819192B080808#,
      16#080819192B190819#, 16#0808192B08082B19#, 16#0808192B08190808#, 16#0808192B19080808#,
      16#0808192B2B081908#, 16#0808192B2B2B1908#, 16#08082B0808080808#, 16#08082B0808081919#,
      16#08082B0808082B08#, 16#08082B0808191908#, 16#08082B08082B2B08#, 16#08082B0819080819#,
      16#08082B0819081908#, 16#08082B0819190808#, 16#08082B081919082B#, 16#08082B082B082B08#,
      16#08082B1908081908#, 16#08082B1919080808#, 16#08082B2B0808082B#, 16#08082B2B08191908#,
      16#0819080808080819#, 16#0819080808081908#, 16#0819080808190808#, 16#08190808082B0819#,
      16#0819080819080808#, 16#08190808192B0808#, 16#081908082B081908#, 16#081908082B190808#,
      16#081908082B191919#, 16#0819081908080808#, 16#0819081908082B08#, 16#08190819082B0808#,
      16#0819081919190808#, 16#0819081919192B2B#, 16#081908192B080808#, 16#0819082B082B1908#,
      16#0819082B19081919#, 16#0819190808080808#, 16#0819190808082B08#, 16#08191908082B0808#,
      16#08191908082B1919#, 16#0819190819082B19#, 16#081919082B080808#, 16#0819191908192B08#,
      16#08191919192B082B#, 16#0819192B08080808#, 16#0819192B0819192B#, 16#08192B0808080819#,
      16#08192B0808081908#, 16#08192B0808190808#, 16#08192B0819080808#, 16#08192B082B080819#,
      16#08192B1908080808#, 16#08192B1908081919#, 16#08192B192B2B0808#, 16#08192B2B19190819#,
      16#082B080808080808#, 16#082B08080808082B#, 16#082B080808082B2B#, 16#082B080819081908#,
      16#082B0808192B0819#, 16#082B08082B080808#, 16#082B08082B08082B#, 16#082B0819082B2B19#,
      16#082B081919082B08#, 16#082B082B08080808#, 16#082B082B0808082B#, 16#082B190808080819#,
      16#082B190808081908#, 16#082B190808190808#, 16#082B190819080808#, 16#082B19081919192B#,
      16#082B191908080808#, 16#082B191919080819#, 16#082B1919192B1908#, 16#082B192B2B190808#,
      16#082B2B0808082B08#, 16#082B2B08082B0808#, 16#082B2B082B191908#, 16#082B2B2B19081908#,
      16#1908080808080819#, 16#1908080808081908#, 16#1908080808190808#, 16#1908080808192B08#,
      16#19080808082B0819#, 16#19080808082B1908#, 16#1908080819080808#, 16#1908080819082B08#,
      16#190808081919192B#, 16#19080808192B0808#, 16#190808082B080819#, 16#190808082B081908#,
      16#190808082B190808#, 16#1908081908080808#, 16#19080819082B0808#, 16#19080819192B0819#,
      16#190808192B080808#, 16#190808192B081919#, 16#1908082B08080819#, 16#1908082B08190808#,
      16#1908082B19082B08#, 16#1908082B1919192B#, 16#1908082B192B2B08#, 16#1908190808080808#,
      16#1908190808082B08#, 16#19081908082B0808#, 16#190819082B080808#, 16#190819082B192B19#,
      16#190819190819082B#, 16#19081919082B1908#, 16#1908192B08080808#, 16#19082B0808080819#,
      16#19082B0808081908#, 16#19082B0808190808#, 16#19082B0819080808#, 16#19082B0819081919#,
      16#19082B1908080808#, 16#19082B1919192B08#, 16#19082B19192B0819#, 16#19082B192B08082B#,
      16#19082B2B19081919#, 16#19082B2B2B190808#, 16#1919080808080808#, 16#1919080808082B08#,
      16#1919080808190819#, 16#1919080808192B19#, 16#19190808082B0808#, 16#191908082B080808#,
      16#191908082B082B08#, 16#1919081908081908#, 16#191908191908082B#, 16#191908192B2B1908#,
      16#1919082B2B190819#, 16#191919082B190808#, 16#191919082B19082B#, 16#1919191908082B2B#,
      16#1919192B08080819#, 16#1919192B19191908#, 16#19192B0808080808#, 16#19192B0808190819#,
      16#19192B0808192B19#, 16#19192B08192B1908#, 16#19192B1919080808#, 16#19192B2B08082B08#,
      16#192B080808081908#, 16#192B080808190808#, 16#192B080819080808#, 16#192B0808192B2B08#,
      16#192B081908080808#, 16#192B081919191919#, 16#192B082B08192B08#, 16#192B082B192B0808#,
      16#192B190808080808#, 16#192B190808081919#, 16#192B191908190808#, 16#192B19190819082B#,
      16#192B19192B081908#, 16#192B2B081908082B#, 16#2B08080808080808#, 16#2B0808080808082B#,
      16#2B08080808082B2B#, 16#2B08080819080819#, 16#2B0808082B08082B#, 16#2B08081908081908#,
      16#2B08081908192B08#, 16#2B08081919080808#, 16#2B08082B08190819#, 16#2B08190808080819#,
      16#2B08190808081908#, 16#2B08190808190808#, 16#2B08190808191919#, 16#2B08190819080808#,
      16#2B081908192B0808#, 16#2B08191908080808#, 16#2B0819191908192B#, 16#2B0819192B191908#,
      16#2B08192B08082B19#, 16#2B08192B19080808#, 16#2B08192B192B0808#, 16#2B082B080808082B#,
      16#2B082B1908081908#, 16#2B082B2B08190819#, 16#2B19080808081908#, 16#2B19080808190808#,
      16#2B190808082B1908#, 16#2B19080819080808#, 16#2B1908082B2B0819#, 16#2B1908190819192B#,
      16#2B1908192B080808#, 16#2B19082B19081919#, 16#2B19190808080808#, 16#2B191908082B082B#,
      16#2B19190819081908#, 16#2B19191919190819#, 16#2B192B082B080819#, 16#2B192B19082B0808#,
      16#2B2B08080808082B#, 16#2B2B080819190808#, 16#2B2B08082B081919#, 16#2B2B081908082B19#,
      16#2B2B082B08080808#, 16#2B2B190808192B08#, 16#2B2B2B0819190808#, 16#2B2B2B1908081908#];

   --  The 128 sign patterns IQ2 formats share: a seven-bit index into an
   --  eight-bit mask, its top bit the parity that makes the whole even.
   --  Transcribed from llama.cpp's ksigns_iq2xs (ggml-common.h).
   KSigns_IQ2XS : constant array (0 .. 127) of Interfaces.Unsigned_8 :=
     [
      0, 129, 130, 3, 132, 5, 6, 135, 136, 9, 10, 139, 12, 141, 142, 15,
      144, 17, 18, 147, 20, 149, 150, 23, 24, 153, 154, 27, 156, 29, 30, 159,
      160, 33, 34, 163, 36, 165, 166, 39, 40, 169, 170, 43, 172, 45, 46, 175,
      48, 177, 178, 51, 180, 53, 54, 183, 184, 57, 58, 187, 60, 189, 190, 63,
      192, 65, 66, 195, 68, 197, 198, 71, 72, 201, 202, 75, 204, 77, 78, 207,
      80, 209, 210, 83, 212, 85, 86, 215, 216, 89, 90, 219, 92, 221, 222, 95,
      96, 225, 226, 99, 228, 101, 102, 231, 232, 105, 106, 235, 108, 237, 238, 111,
      240, 113, 114, 243, 116, 245, 246, 119, 120, 249, 250, 123, 252, 125, 126, 255];


   --  MXFP4's own sixteen, which are the E2M1 floating-point values at twice
   --  their size: 0, 0.5, 1, 1.5, 2, 3, 4, 6 and the same again negated.
   --  Doubling them keeps the table whole, and the scale below carries the
   --  halving -- which is why the exponent is read as two to the e less a
   --  hundred and twenty-eight rather than a hundred and twenty-seven.
   Fours : constant array (0 .. 15) of Integer :=
     [0, 1, 2, 3, 4, 6, 8, 12, 0, -1, -2, -3, -4, -6, -8, -12];

   --  Read one byte of a block. The caller has already checked that the whole
   --  block lies inside Data.
   function Raw
     (Data   : B.Byte_Array;
      Offset : B.Byte_Count) return Interfaces.Unsigned_8
   is (Interfaces.Unsigned_8 (Data (Data'First + Offset)));

   --  Read a signed byte of a block.
   --  One read, not three: deciding the sign used to re-read the byte.
   function Signed
     (Data   : B.Byte_Array;
      Offset : B.Byte_Count) return Integer
   is
      Value : constant Interfaces.Unsigned_8 := Raw (Data, Offset);
   begin
      return (if Value < 128 then Integer (Value) else Integer (Value) - 256);
   end Signed;

   --  Read a half-precision scale.
   function Scale
     (Data   : B.Byte_Array;
      Offset : B.Byte_Count) return Real
   is (N.To_Real
         (N.Half
            (Interfaces.Unsigned_16 (Raw (Data, Offset))
             or Interfaces.Shift_Left
                  (Interfaces.Unsigned_16 (Raw (Data, Offset + 1)), 8))));

   --  Unpack the six-bit scale and minimum of one k-quant sub-block.
   --
   --  The twelve scale bytes hold eight scale/minimum pairs: the first four
   --  pairs use six bits of one byte each, and the last four are split across
   --  the high bits of the earlier bytes. This is the layout every k-quant
   --  format shares.
   procedure Sub_Block_Scale
     (Data    : B.Byte_Array;
      Base    : B.Byte_Count;
      Index   : Natural;
      Factor  : out Interfaces.Unsigned_8;
      Minimum : out Interfaces.Unsigned_8)
   is
      function Byte_At (Position : Natural) return Interfaces.Unsigned_8
      is (Raw (Data, Base + B.Byte_Count (Position)));
   begin
      if Index < 4 then
         Factor := Byte_At (Index) and 63;
         Minimum := Byte_At (Index + 4) and 63;
      else
         Factor :=
           (Byte_At (Index + 4) and 16#0F#)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Byte_At (Index - 4), 6), 4);
         Minimum :=
           Interfaces.Shift_Right (Byte_At (Index + 4), 4)
           or Interfaces.Shift_Left
                (Interfaces.Shift_Right (Byte_At (Index), 6), 4);
      end if;
   end Sub_Block_Scale;
   --  span decoder below uses it directly for the formats whose blocks are
   --  wide enough that a per-block call costs nothing measurable, and repeats
   --  its inner loop for the narrow ones.
   procedure Decode_One
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Target : out Real_Array;
      Ok     : out Boolean)
   is
      Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
   begin
      Ok := False;

      if not Is_Decodable (Format)
        or else not B.Has_Room (Data, Offset, Width)
      then
         --  Only the failure path leaves the buffer undefined, so only it has
         --  to define one. Every format branch below writes each of the
         --  elements its layout declares, and callers read no further: the
         --  buffer is sized for the widest format, not for this one.
         --
         --  Zeroing it unconditionally cost far more than the decode. A Q8_0
         --  block is 32 elements in a 256-element buffer, so eight of every
         --  nine bytes written were discarded, and at roughly a billion
         --  multiply-accumulates per token that came to tens of gigabytes of
         --  wasted stores for each token produced.
         Target := [others => 0.0];
         return;
      end if;

      --  Only the k-quant formats reach here: Decode_Blocks unpacks the
      --  others inline and delegates the rest to this. A second copy of the
      --  simple layouts lived here and nothing called it, so nothing tested
      --  it either.
      case Format is
         when G.Type_Q4_1 =>
            --  As Q4_0, with a minimum of its own instead of a fixed bias of
            --  eight: the block carries two half-precision numbers, and a
            --  nibble is scaled and then lifted rather than centred.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D      : constant Real := Scale (Data, Offset);
               Lowest : constant Real := Scale (Data, Offset + 2);
               Base   : constant B.Byte_Index := Data'First + Offset + 4;
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Data (Base + B.Byte_Count (J));
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Integer (Packed and 16#0F#)) + Lowest;
                     Target (Target'First + Element_Count (J) + 16) :=
                       D * Real (Integer (Interfaces.Shift_Right (Packed, 4)))
                       + Lowest;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_IQ4_NL =>
            --  Thirty-two elements, a half-precision scale, then sixteen
            --  bytes of nibbles laid out as Q4_0 lays them: the low nibble
            --  of byte j is element j and the high nibble is element j + 16.
            --  What differs is what a nibble means -- an index into the
            --  level table rather than a number to centre on eight.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D    : constant Real := Scale (Data, Offset);
               Base : constant B.Byte_Index := Data'First + Offset + 2;
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Data (Base + B.Byte_Count (J));
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Levels (Integer (Packed and 16#0F#)));
                     Target (Target'First + Element_Count (J) + 16) :=
                       D * Real
                             (Levels
                                (Integer
                                   (Interfaces.Shift_Right (Packed, 4))));
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_MXFP4 =>
            --  Thirty-two elements in seventeen bytes: one exponent byte,
            --  then sixteen of nibbles laid out as Q4_0 lays them -- the low
            --  nibble of byte j is element j and the high nibble is element
            --  j plus sixteen.
            --
            --  The scale is a power of two rather than a half. The byte is
            --  an E8M0 exponent, so the multiplier is two to the byte less a
            --  hundred and twenty-eight: less a hundred and twenty-seven for
            --  the exponent's own bias, and one more because the table above
            --  holds twice each value. That is one expression for every byte
            --  including zero and one, where a bit pattern would need two.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               --  The scale is a bit pattern, not a power to compute.
               --  Two to the byte less a hundred and twenty-eight has a
               --  biased exponent of the byte less one and no mantissa, so
               --  the whole of it is a shift -- and the two bytes below that
               --  are subnormal, where the shift is of the leading bit
               --  instead. This is what llama.cpp's E8M0 conversion does and
               --  it is exact where a power taken at run time need not be.
               --
               --  It bought nothing measurable and is kept for being the
               --  right way to say it: written as `2.0 ** (Integer - 128)`
               --  this format read 0.98 nanoseconds an element, and written
               --  this way it read 0.98 as well. What the format was
               --  actually short of was the wide compilation -- its nibble
               --  is an index into a table, which is the shape that
               --  compilation exists for, and it was not on the list. On it,
               --  0.59.
               Bits : constant Interfaces.Unsigned_32 :=
                 (if Raw (Data, Offset) < 2
                  then Interfaces.Shift_Left
                         (16#0020_0000#, Natural (Raw (Data, Offset)))
                  else Interfaces.Shift_Left
                         (Interfaces.Unsigned_32 (Raw (Data, Offset)) - 1,
                          23));

               D : constant Real := N.From_Bits (Bits);

               Base : constant B.Byte_Index := Data'First + Offset + 1;
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Data (Base + B.Byte_Count (J));
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Fours (Integer (Packed and 16#0F#)));
                     Target (Target'First + Element_Count (J) + 16) :=
                       D * Real
                             (Fours
                                (Integer
                                   (Interfaces.Shift_Right (Packed, 4))));
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_IQ4_XS =>
            --  The same levels over a super-block: two hundred and fifty-six
            --  elements in eight sub-blocks of thirty-two, one
            --  half-precision scale for the whole block and a six-bit scale
            --  for each sub-block. Those six bits are split -- four in a
            --  nibble of scales_l and two in a field of scales_h -- and the
            --  value they carry is signed by subtracting thirty-two.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D : constant Real := Scale (Data, Offset);

               High : constant Interfaces.Unsigned_16 :=
                 Interfaces.Unsigned_16 (Data (Data'First + Offset + 2))
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_16
                         (Data (Data'First + Offset + 3)), 8);

               Low  : constant B.Byte_Index := Data'First + Offset + 4;
               Base : constant B.Byte_Index := Data'First + Offset + 8;
            begin
               for Sub in 0 .. 7 loop
                  declare
                     Nibble : constant Interfaces.Unsigned_8 :=
                       (if Sub mod 2 = 0
                        then Data (Low + B.Byte_Count (Sub / 2)) and 16#0F#
                        else Interfaces.Shift_Right
                               (Data (Low + B.Byte_Count (Sub / 2)), 4));

                     Upper : constant Interfaces.Unsigned_16 :=
                       Interfaces.Shift_Right (High, 2 * Sub) and 3;

                     Level : constant Integer :=
                       Integer (Nibble) + 16 * Integer (Upper);

                     Step : constant Real := D * Real (Level - 32);

                     At_Byte : constant B.Byte_Index :=
                       Base + B.Byte_Count (Sub) * 16;
                     Slot    : constant Element_Count :=
                       Target'First + Element_Count (Sub) * 32;
                  begin
                     for J in 0 .. 15 loop
                        declare
                           Packed : constant Interfaces.Unsigned_8 :=
                             Data (At_Byte + B.Byte_Count (J));
                        begin
                           Target (Slot + Element_Count (J)) :=
                             Step * Real (Levels (Integer (Packed and 16#0F#)));
                           Target (Slot + Element_Count (J) + 16) :=
                             Step * Real
                                      (Levels
                                         (Integer
                                            (Interfaces.Shift_Right
                                               (Packed, 4))));
                        end;
                     end loop;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_IQ3_S =>
            --  A super-block of two hundred and fifty-six through a grid of
            --  five hundred and twelve four-value entries. Each of the eight
            --  sub-blocks of thirty-two carries eight nine-bit indices -- a
            --  qs byte and a high bit out of a qh byte -- four sign bytes,
            --  and a four-bit scale, its low or high nibble by turn. Each
            --  grid entry's four bytes are four values, signed and scaled.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D      : constant Real := Scale (Data, Offset);
               QS     : constant B.Byte_Index := Data'First + Offset + 2;
               QH     : constant B.Byte_Index := Data'First + Offset + 66;
               Sgn    : constant B.Byte_Index := Data'First + Offset + 74;
               Scales : constant B.Byte_Index := Data'First + Offset + 106;
            begin
               for Sub in 0 .. 7 loop
                  declare
                     Scale_Byte : constant Interfaces.Unsigned_8 :=
                       Data (Scales + B.Byte_Count (Sub / 2));
                     Nibble : constant Interfaces.Unsigned_8 :=
                       (if Sub mod 2 = 0 then Scale_Byte and 16#0F#
                        else Interfaces.Shift_Right (Scale_Byte, 4));
                     DB : constant Real := D * Real (1 + 2 * Integer (Nibble));
                     QH_Byte : constant Interfaces.Unsigned_8 :=
                       Data (QH + B.Byte_Count (Sub));
                     QS_Sub  : constant B.Byte_Index :=
                       QS + B.Byte_Count (Sub) * 8;
                     Sign_Sub : constant B.Byte_Index :=
                       Sgn + B.Byte_Count (Sub) * 4;
                  begin
                     for L in 0 .. 3 loop
                        declare
                           High_1 : constant Interfaces.Unsigned_32 :=
                             (if (QH_Byte
                                    and Interfaces.Unsigned_8 (2 ** (2 * L)))
                                  /= 0
                              then 256 else 0);
                           High_2 : constant Interfaces.Unsigned_32 :=
                             (if (QH_Byte
                                    and Interfaces.Unsigned_8
                                          (2 ** (2 * L + 1)))
                                  /= 0
                              then 256 else 0);
                           G1 : constant Interfaces.Unsigned_32 :=
                             IQ3S_Grid
                               (Natural
                                  (Interfaces.Unsigned_32
                                     (Data (QS_Sub + B.Byte_Count (2 * L)))
                                   or High_1));
                           G2 : constant Interfaces.Unsigned_32 :=
                             IQ3S_Grid
                               (Natural
                                  (Interfaces.Unsigned_32
                                     (Data (QS_Sub + B.Byte_Count (2 * L + 1)))
                                   or High_2));
                           Sign_Byte : constant Interfaces.Unsigned_8 :=
                             Data (Sign_Sub + B.Byte_Count (L));
                           Slot : constant Element_Count :=
                             Target'First + Element_Count (Sub) * 32
                             + Element_Count (L) * 8;
                        begin
                           for J in 0 .. 3 loop
                              declare
                                 V1 : constant Real := Real
                                   (Integer
                                      (Interfaces.Shift_Right (G1, 8 * J)
                                       and 16#FF#));
                                 V2 : constant Real := Real
                                   (Integer
                                      (Interfaces.Shift_Right (G2, 8 * J)
                                       and 16#FF#));
                                 S1 : constant Real :=
                                   (if (Sign_Byte
                                          and Interfaces.Unsigned_8 (2 ** J))
                                        /= 0
                                    then -1.0 else 1.0);
                                 S2 : constant Real :=
                                   (if (Sign_Byte
                                          and Interfaces.Unsigned_8
                                                (2 ** (J + 4)))
                                        /= 0
                                    then -1.0 else 1.0);
                              begin
                                 Target (Slot + Element_Count (J)) :=
                                   DB * V1 * S1;
                                 Target (Slot + Element_Count (J) + 4) :=
                                   DB * V2 * S2;
                              end;
                           end loop;
                        end;
                     end loop;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_IQ2_XXS =>
            --  A super-block of two hundred and fifty-six through a grid of
            --  two hundred and fifty-six eight-value entries. Each of the
            --  eight sub-blocks of thirty-two is two thirty-two-bit words:
            --  the first four bytes are four grid indices, the second word
            --  four seven-bit sign indices and, in its top four bits, a
            --  scale. A grid entry's eight bytes are eight magnitudes,
            --  signed by the pattern the index names and scaled.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D  : constant Real := Scale (Data, Offset);
               QS : constant B.Byte_Index := Data'First + Offset + 2;
            begin
               for Sub in 0 .. 7 loop
                  declare
                     Base : constant B.Byte_Index :=
                       QS + B.Byte_Count (Sub) * 8;
                     Aux1 : constant Interfaces.Unsigned_32 :=
                       Interfaces.Unsigned_32 (Data (Base + 4))
                       or Interfaces.Shift_Left
                            (Interfaces.Unsigned_32 (Data (Base + 5)), 8)
                       or Interfaces.Shift_Left
                            (Interfaces.Unsigned_32 (Data (Base + 6)), 16)
                       or Interfaces.Shift_Left
                            (Interfaces.Unsigned_32 (Data (Base + 7)), 24);
                     DB : constant Real :=
                       D * (0.5 + Real (Integer
                              (Interfaces.Shift_Right (Aux1, 28)))) * 0.25;
                  begin
                     for L in 0 .. 3 loop
                        declare
                           Grid : constant Interfaces.Unsigned_64 :=
                             IQ2XXS_Grid
                               (Natural (Data (Base + B.Byte_Count (L))));
                           Signs : constant Interfaces.Unsigned_8 :=
                             KSigns_IQ2XS
                               (Natural
                                  (Interfaces.Shift_Right
                                     (Aux1, 7 * L) and 127));
                           Slot : constant Element_Count :=
                             Target'First + Element_Count (Sub) * 32
                             + Element_Count (L) * 8;
                        begin
                           for J in 0 .. 7 loop
                              declare
                                 GByte : constant Interfaces.Unsigned_64 :=
                                   Interfaces.Shift_Right
                                     (Grid, 8 * J) and 16#FF#;
                                 Sgn : constant Real :=
                                   (if (Signs
                                          and Interfaces.Unsigned_8 (2 ** J))
                                        /= 0
                                    then -1.0 else 1.0);
                              begin
                                 Target (Slot + Element_Count (J)) :=
                                   DB * Real (Integer (GByte)) * Sgn;
                              end;
                           end loop;
                        end;
                     end loop;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q5_0 | G.Type_Q5_1 =>
            --  A fifth bit for each element, held apart from the nibbles in
            --  four bytes read as one number: bit j belongs to element j and
            --  bit j + 16 to element j + 16, which is the same rule the
            --  five-bit super-block uses kept in a different place.
            --
            --  These two cost about two and a half times what the four-bit
            --  formats do -- 1.05 nanoseconds an element against 0.43 -- and
            --  the fifth bit is the whole of it. Every other format finds its
            --  extra bits at a fixed place in a byte it is already reading;
            --  here the bit for element j is bit j of a thirty-two bit word,
            --  so the shift amount varies with the element and the loop
            --  cannot be vectorized by an instruction set without a per-lane
            --  shift. Baseline x86-64 has none, and compiling for a host that
            --  does measured slower everywhere else, which is in the README.
            --  Turning the two conditionals into shifts was tried and changed
            --  nothing, which is what said the branch was not the cost.
            --
            --  The two differ only in what happens once the fifth bit is
            --  restored. Q5_0 centres the result by subtracting sixteen, as
            --  Q4_0 subtracts eight; Q5_1 carries a minimum instead, as Q4_1
            --  does. Everything else is the same, which is why they share a
            --  branch rather than repeating one.
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               Centred : constant Boolean := Format = G.Type_Q5_0;

               --  Q5_0 keeps the fifth bits straight after its one scale;
               --  Q5_1 keeps them after its two.
               Fifths_At : constant B.Byte_Count := (if Centred then 2 else 4);
               Quants_At : constant B.Byte_Count := (if Centred then 6 else 8);

               D      : constant Real := Scale (Data, Offset);
               Lowest : constant Real :=
                 (if Centred then 0.0 else Scale (Data, Offset + 2));
               Bias   : constant Integer := (if Centred then 16 else 0);

               Head   : constant B.Byte_Index := Data'First + Offset;
               Base   : constant B.Byte_Index := Head + Quants_At;

               Fifths : constant Interfaces.Unsigned_32 :=
                 Interfaces.Unsigned_32 (Data (Head + Fifths_At))
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Data (Head + Fifths_At + 1)), 8)
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Data (Head + Fifths_At + 2)), 16)
                 or Interfaces.Shift_Left
                      (Interfaces.Unsigned_32
                         (Data (Head + Fifths_At + 3)), 24);
            begin
               for J in 0 .. 15 loop
                  declare
                     Packed : constant Interfaces.Unsigned_8 :=
                       Data (Base + B.Byte_Count (J));
                     Low_Fifth : constant Integer :=
                       (if (Interfaces.Shift_Right (Fifths, J) and 1) = 1
                        then 16 else 0);
                     High_Fifth : constant Integer :=
                       (if (Interfaces.Shift_Right (Fifths, J + 16) and 1) = 1
                        then 16 else 0);
                  begin
                     Target (Target'First + Element_Count (J)) :=
                       D * Real (Integer (Packed and 16#0F#)
                                 + Low_Fifth - Bias)
                       + Lowest;
                     Target (Target'First + Element_Count (J) + 16) :=
                       D * Real (Integer (Interfaces.Shift_Right (Packed, 4))
                                 + High_Fifth - Bias)
                       + Lowest;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q2_K =>
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               --  Sixteen bytes of packed scales, then sixty-four bytes of
               --  quants at two bits each, then the two half-precision
               --  factors. Every element is one of four levels, so the format
               --  leans harder on its scales than any other here: sixteen
               --  sub-blocks of sixteen elements, each with a four-bit scale
               --  and a four-bit minimum sharing one byte.
               Scales  : constant B.Byte_Count := Offset;
               Quants  : constant B.Byte_Count := Offset + 16;
               D       : constant Real := Scale (Data, Offset + 80);
               Minimum : constant Real := Scale (Data, Offset + 82);
            begin
               for Half in 0 .. 1 loop
                  for Group in 0 .. 3 loop
                     for Upper in 0 .. 1 loop
                        declare
                           --  The scales are consumed in the order the
                           --  sub-blocks are written, which is why this is a
                           --  running index rather than an offset computed
                           --  from the element number.
                           Which : constant B.Byte_Count :=
                             B.Byte_Count (Half * 8 + Group * 2 + Upper);
                           Packed : constant Interfaces.Unsigned_8 :=
                             Data (Data'First + Scales + Which);

                           Factor : constant Real :=
                             D * Real (Integer (Packed and 16#0F#));
                           Lowest : constant Real :=
                             Minimum
                             * Real (Integer
                                       (Interfaces.Shift_Right (Packed, 4)));

                           --  Sixteen adjacent bytes to sixteen adjacent
                           --  elements, as everywhere else here.
                           From : constant B.Byte_Count :=
                             Quants + B.Byte_Count (Half * 32 + Upper * 16);
                           Into : constant Element_Count :=
                             Element_Count (Half * 128 + Group * 32
                                            + Upper * 16);
                           Shift : constant Natural := 2 * Group;
                        begin
                           for L in 0 .. 15 loop
                              Target
                                (Target'First + Into + Element_Count (L)) :=
                                Factor
                                * Real (Integer
                                          (Interfaces.Shift_Right
                                             (Data (Data'First + From
                                                    + B.Byte_Count (L)),
                                              Shift)
                                           and 3))
                                - Lowest;
                           end loop;
                        end;
                     end loop;
                  end loop;
               end loop;
               Ok := True;
            end;

         when G.Type_Q3_K =>
            declare
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               --  Three bits an element, in two pieces. The low two are
               --  packed four to a byte as in the two-bit format; the third
               --  lives in a mask of thirty-two bytes shared by the whole
               --  block, one bit per element position per sub-block group,
               --  and it is the bit's absence that lowers the value: set
               --  leaves the two low bits alone, clear takes four away, which
               --  is what makes the range minus four to three rather than
               --  zero to seven.
               High    : constant B.Byte_Count := Offset;
               Quants  : constant B.Byte_Count := Offset + 32;
               Scales  : constant B.Byte_Count := Offset + 96;
               D       : constant Real := Scale (Data, Offset + 108);

               --  The sixteen sub-block scales are six bits each, packed
               --  across twelve bytes: four low bits in one of the first
               --  eight bytes, two high bits in one of the last four. Which
               --  of the four groups a sub-block falls in decides both where
               --  its nibble comes from and how far its two bits are shifted.
               function Sub_Scale (Which : Natural) return Integer is
                  Group : constant Natural := Which / 4;
                  Place : constant B.Byte_Count := B.Byte_Count (Which mod 4);

                  Low_Byte : constant Interfaces.Unsigned_8 :=
                    Data (Data'First + Scales
                          + (if Group mod 2 = 0 then Place else Place + 4));
                  Low : constant Interfaces.Unsigned_8 :=
                    (if Group < 2
                     then Low_Byte and 16#0F#
                     else Interfaces.Shift_Right (Low_Byte, 4));

                  Top : constant Interfaces.Unsigned_8 :=
                    Interfaces.Shift_Right
                      (Data (Data'First + Scales + Place + 8),
                       2 * Group)
                    and 3;
               begin
                  return Integer (Low) + 16 * Integer (Top) - 32;
               end Sub_Scale;
            begin
               for Half in 0 .. 1 loop
                  for Group in 0 .. 3 loop
                     for Upper in 0 .. 1 loop
                        declare
                           Which : constant Natural :=
                             Half * 8 + Group * 2 + Upper;
                           Factor : constant Real :=
                             D * Real (Sub_Scale (Which));

                           From : constant B.Byte_Count :=
                             Quants + B.Byte_Count (Half * 32 + Upper * 16);
                           Mask_At : constant B.Byte_Count :=
                             High + B.Byte_Count (Upper * 16);
                           Into : constant Element_Count :=
                             Element_Count (Half * 128 + Group * 32
                                            + Upper * 16);
                           Shift : constant Natural := 2 * Group;

                           --  One bit of the mask serves one sub-block
                           --  group, and the bit advances across the whole
                           --  block rather than restarting at its middle.
                           Bit : constant Interfaces.Unsigned_8 :=
                             Interfaces.Shift_Left (1, Half * 4 + Group);
                        begin
                           for L in 0 .. 15 loop
                              declare
                                 Low : constant Integer :=
                                   Integer
                                     (Interfaces.Shift_Right
                                        (Data (Data'First + From
                                               + B.Byte_Count (L)),
                                         Shift)
                                      and 3);
                                 Lifted : constant Boolean :=
                                   (Data (Data'First + Mask_At
                                          + B.Byte_Count (L)) and Bit) /= 0;
                              begin
                                 Target
                                   (Target'First + Into + Element_Count (L)) :=
                                   Factor
                                   * Real (if Lifted then Low else Low - 4);
                              end;
                           end loop;
                        end;
                     end loop;
                  end loop;
               end loop;
               Ok := True;
            end;

         when G.Type_Q4_K =>
            declare
               --  The block was bounds-checked at entry, so every index below
               --  is inside it. The checks cost the vectorizer this loop, and
               --  unpacking is the larger half of a k-quant row's cost.
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D       : constant Real := Scale (Data, Offset);
               Minimum : constant Real := Scale (Data, Offset + 2);
               Scales  : constant B.Byte_Count := Offset + 4;
               Quants  : constant B.Byte_Count := Offset + 16;
               Target_Index : Element_Count := 0;
               Sub     : Natural := 0;
            begin
               --  Eight sub-blocks of 32 elements, processed in pairs that
               --  share the same 32 packed bytes: the low nibbles form the
               --  first sub-block and the high nibbles the second.
               for Group in 0 .. 3 loop
                  declare
                     Base    : constant B.Byte_Count :=
                       Quants + B.Byte_Count (Group) * 32;
                     Factor1, Min1, Factor2, Min2 : Interfaces.Unsigned_8;
                  begin
                     Sub_Block_Scale (Data, Scales, Sub, Factor1, Min1);
                     Sub_Block_Scale (Data, Scales, Sub + 1, Factor2, Min2);

                     --  A sub-block's scale and offset are the same for all
                     --  thirty-two of its elements, so they are formed once
                     --  here rather than in the loop. They were four
                     --  multiplies and four conversions per element.
                     declare
                        Scale_1  : constant Real := D * Real (Factor1);
                        Scale_2  : constant Real := D * Real (Factor2);
                        Offset_1 : constant Real := Minimum * Real (Min1);
                        Offset_2 : constant Real := Minimum * Real (Min2);
                     begin
                        for L in 0 .. 31 loop
                           declare
                              --  Indexed directly rather than through Raw:
                              --  one read instead of a call per element.
                              Packed : constant Interfaces.Unsigned_8 :=
                                Data (Data'First + Base + B.Byte_Count (L));
                           begin
                              Target
                                (Target'First + Target_Index
                                 + Element_Count (L)) :=
                                Scale_1 * Real (Integer (Packed and 16#0F#))
                                - Offset_1;
                              Target
                                (Target'First + Target_Index + 32
                                 + Element_Count (L)) :=
                                Scale_2
                                  * Real (Integer
                                            (Interfaces.Shift_Right
                                               (Packed, 4)))
                                - Offset_2;
                           end;
                        end loop;
                     end;

                     Target_Index := Target_Index + 64;
                     Sub := Sub + 2;
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q5_K =>
            declare
               --  As in Q4_K: the block was bounds-checked at entry, and
               --  the per-element checks cost the vectorizer this loop.
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               D       : constant Real := Scale (Data, Offset);
               Minimum : constant Real := Scale (Data, Offset + 2);
               Scales  : constant B.Byte_Count := Offset + 4;
               High    : constant B.Byte_Count := Offset + 16;
               Quants  : constant B.Byte_Count := Offset + 48;
               Target_Index : Element_Count := 0;
               Sub     : Natural := 0;
               Mask_Low  : Interfaces.Unsigned_8 := 1;
               Mask_High : Interfaces.Unsigned_8 := 2;
            begin
               for Group in 0 .. 3 loop
                  declare
                     Base    : constant B.Byte_Count :=
                       Quants + B.Byte_Count (Group) * 32;
                     Factor1, Min1, Factor2, Min2 : Interfaces.Unsigned_8;
                  begin
                     Sub_Block_Scale (Data, Scales, Sub, Factor1, Min1);
                     Sub_Block_Scale (Data, Scales, Sub + 1, Factor2, Min2);

                     --  Formed once per sub-block rather than once per
                     --  element, as in Q4_K.
                     declare
                        Scale_1  : constant Real := D * Real (Factor1);
                        Scale_2  : constant Real := D * Real (Factor2);
                        Offset_1 : constant Real := Minimum * Real (Min1);
                        Offset_2 : constant Real := Minimum * Real (Min2);
                     begin

                        for L in 0 .. 31 loop
                           declare
                              Packed : constant Interfaces.Unsigned_8 :=
                                Data (Data'First + Base + B.Byte_Count (L));
                              Fifth  : constant Interfaces.Unsigned_8 :=
                                Data (Data'First + High + B.Byte_Count (L));
                              Low    : constant Integer :=
                                Integer (Packed and 16#0F#)
                                + (if (Fifth and Mask_Low) /= 0 then 16 else 0);
                              Upper  : constant Integer :=
                                Integer (Interfaces.Shift_Right (Packed, 4))
                                + (if (Fifth and Mask_High) /= 0 then 16 else 0);
                           begin
                              Target
                                (Target'First + Target_Index
                                 + Element_Count (L)) :=
                                Scale_1 * Real (Low) - Offset_1;
                              Target
                                (Target'First + Target_Index + 32
                                 + Element_Count (L)) :=
                                Scale_2 * Real (Upper) - Offset_2;
                           end;
                        end loop;
                     end;

                     Target_Index := Target_Index + 64;
                     Sub := Sub + 2;
                     Mask_Low := Interfaces.Shift_Left (Mask_Low, 2);
                     Mask_High := Interfaces.Shift_Left (Mask_High, 2);
                  end;
               end loop;
               Ok := True;
            end;

         when G.Type_Q6_K =>
            declare
               --  As in Q4_K: the block was bounds-checked at entry, and
               --  the per-element checks cost the vectorizer this loop.
               pragma Suppress (Index_Check);
               pragma Suppress (Range_Check);
               pragma Suppress (Overflow_Check);

               Low_Base  : constant B.Byte_Count := Offset;
               High_Base : constant B.Byte_Count := Offset + 128;
               Scale_Base : constant B.Byte_Count := Offset + 192;
               D : constant Real := Scale (Data, Offset + 208);
            begin
               --  Two halves of 128 elements. Within a half, each of the 32
               --  positions contributes four elements whose two high bits come
               --  from one byte of the high-bit array.
               for Half in 0 .. 1 loop
                  declare
                     Low_Half   : constant B.Byte_Count :=
                       Low_Base + B.Byte_Count (Half) * 64;
                     High_Half  : constant B.Byte_Count :=
                       High_Base + B.Byte_Count (Half) * 32;
                     Scale_Half : constant B.Byte_Count :=
                       Scale_Base + B.Byte_Count (Half) * 8;
                     Out_Half   : constant Element_Count :=
                       Element_Count (Half) * 128;
                  begin
                     --  The four scales depend only on which half of the
                     --  thirty-two positions L is in, so the loop is split
                     --  and they are formed twice rather than 128 times.
                     --
                     --  Each of the four runs below reads sixteen adjacent
                     --  bytes and writes sixteen adjacent elements. Doing
                     --  all four inside one loop, as this once did, wrote
                     --  four streams thirty-two elements apart on every
                     --  iteration, and that scattering is what left this
                     --  format decoding several times slower than the
                     --  others rather than at their speed.
                     for Sub in 0 .. 1 loop
                        declare
                           Low_Run  : constant B.Byte_Count :=
                              Low_Half + B.Byte_Count (Sub) * 16;
                           High_Run : constant B.Byte_Count :=
                              High_Half + B.Byte_Count (Sub) * 16;
                           Out_Run  : constant Element_Count :=
                              Out_Half + Element_Count (Sub) * 16;

                           Scale_1 : constant Real :=
                              D * Real (Signed (Data, Scale_Half
                                                + B.Byte_Count (Sub)));
                           Scale_2 : constant Real :=
                              D * Real (Signed (Data, Scale_Half
                                                + B.Byte_Count (Sub + 2)));
                           Scale_3 : constant Real :=
                              D * Real (Signed (Data, Scale_Half
                                                + B.Byte_Count (Sub + 4)));
                           Scale_4 : constant Real :=
                              D * Real (Signed (Data, Scale_Half
                                                + B.Byte_Count (Sub + 6)));
                        begin
                           --  Low nibble of the first thirty-two bytes, with the
                           --  lowest two bits of the shared byte.
                           for L in 0 .. 15 loop
                              Target (Target'First + Out_Run + Element_Count (L)) :=
                                Scale_1
                                * Real (Integer
                                          (Data (Data'First + Low_Run
                                                 + B.Byte_Count (L)) and 16#0F#)
                                      + 16 * Integer
                                                 (Data (Data'First + High_Run
                                                      + B.Byte_Count (L)) and 3)
                                      - 32);
                           end loop;

                           --  Low nibble of the second thirty-two bytes.
                           for L in 0 .. 15 loop
                              Target (Target'First + Out_Run + 32
                                    + Element_Count (L)) :=
                                Scale_2
                                * Real (Integer
                                          (Data (Data'First + Low_Run + 32
                                                 + B.Byte_Count (L)) and 16#0F#)
                                      + 16 * Integer
                                                 (Interfaces.Shift_Right
                                                  (Data (Data'First + High_Run
                                                         + B.Byte_Count (L)), 2)
                                                and 3)
                                      - 32);
                           end loop;

                           --  High nibble of the first thirty-two bytes.
                           for L in 0 .. 15 loop
                              Target (Target'First + Out_Run + 64
                                    + Element_Count (L)) :=
                                Scale_3
                                * Real (Integer
                                          (Interfaces.Shift_Right
                                           (Data (Data'First + Low_Run
                                                  + B.Byte_Count (L)), 4))
                                      + 16 * Integer
                                                 (Interfaces.Shift_Right
                                                  (Data (Data'First + High_Run
                                                         + B.Byte_Count (L)), 4)
                                                and 3)
                                      - 32);
                           end loop;

                           --  High nibble of the second thirty-two bytes.
                           for L in 0 .. 15 loop
                              Target (Target'First + Out_Run + 96
                                    + Element_Count (L)) :=
                                Scale_4
                                * Real (Integer
                                          (Interfaces.Shift_Right
                                           (Data (Data'First + Low_Run + 32
                                                  + B.Byte_Count (L)), 4))
                                      + 16 * Integer
                                                 (Interfaces.Shift_Right
                                                  (Data (Data'First + High_Run
                                                         + B.Byte_Count (L)), 6)
                                                and 3)
                                      - 32);
                           end loop;
                        end;
                     end loop;
                  end;
               end loop;
               Ok := True;
            end;

         when others =>
            Ok := False;
      end case;

      pragma Assert (Super = 256);
   end Decode_One;
   ------------------
   -- Decode_Span --
   ------------------

   procedure Decode_Span
     (Format : G.Tensor_Type;
      Data   : B.Byte_Array;
      Offset : B.Byte_Count;
      Count  : Element_Count;
      Width  : B.Byte_Count;
      Per    : Element_Count;
      Target : out Real_Array;
      Ok     : out Boolean)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      Slot : Element_Count := Target'First;
      Step : B.Byte_Count := Offset;
   begin
      Ok := False;

      for Block in 1 .. Count loop
         --  Straight into the destination. This used to decode into a
         --  scratch block and copy 256 elements out of it, which was the
         --  whole of the difference between this path and the formats
         --  unpacked inline.
         Decode_One (Format, Data, Step, Target (Slot .. Slot + Per - 1), Ok);
         exit when not Ok;
         Slot := Slot + Per;
         Step := Step + Width;
      end loop;
   end Decode_Span;

end Model_Runner.Quantization.Decoders;
