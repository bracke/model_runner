with Tests.Backend_Cases;
with Tests.Catalog_Cases;
with Tests.CLI_Cases;
with Tests.GGUF_Cases;
with Tests.Inference_Cases;
with Tests.Accounting_Cases;
with Tests.Sampling_Cases;
with Tests.Template_Cases;

package body Tests.Suite is

   Result : aliased AUnit.Test_Suites.Test_Suite;

   GGUF_Case      : aliased Tests.GGUF_Cases.Case_Type;
   Inference_Case : aliased Tests.Inference_Cases.Case_Type;
   Sampling_Case  : aliased Tests.Sampling_Cases.Case_Type;
   Accounting_Case : aliased Tests.Accounting_Cases.Case_Type;
   CLI_Case       : aliased Tests.CLI_Cases.Case_Type;
   Catalog_Case   : aliased Tests.Catalog_Cases.Case_Type;
   Backend_Case   : aliased Tests.Backend_Cases.Case_Type;
   Template_Case  : aliased Tests.Template_Cases.Case_Type;

   -----------
   -- Suite --
   -----------

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
   begin
      AUnit.Test_Suites.Add_Test (Result'Access, GGUF_Case'Access);
      AUnit.Test_Suites.Add_Test (Result'Access, Inference_Case'Access);
      AUnit.Test_Suites.Add_Test (Result'Access, Sampling_Case'Access);
      AUnit.Test_Suites.Add_Test (Result'Access, CLI_Case'Access);
      AUnit.Test_Suites.Add_Test (Result'Access, Catalog_Case'Access);
      AUnit.Test_Suites.Add_Test (Result'Access, Backend_Case'Access);
      AUnit.Test_Suites.Add_Test (Result'Access, Accounting_Case'Access);
      AUnit.Test_Suites.Add_Test (Result'Access, Template_Case'Access);
      return Result'Access;
   end Suite;

end Tests.Suite;
