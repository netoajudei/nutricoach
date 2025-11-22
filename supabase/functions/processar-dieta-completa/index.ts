import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders
    }
  });
}
serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders
    });
  }
  try {
    const body = await req.json().catch(()=>({}));
    const { aluno_id, conversation_id, tool_call_id_1, tool_call_id_2, tool_1_args, tool_2_args } = body;
    console.log(`[1] aluno_id: ${aluno_id}`);
    console.log(`[2] conversation_id: ${conversation_id}`);
    console.log(`[3] tool_call_id_1: ${tool_call_id_1}`);
    console.log(`[4] tool_call_id_2: ${tool_call_id_2}`);
    console.log(`[5] tool_1_args:`, tool_1_args);
    console.log(`[6] tool_2_args:`, tool_2_args);
    return jsonResponse({
      success: true,
      recebido: {
        aluno_id,
        conversation_id,
        tool_call_id_1,
        tool_call_id_2,
        tool_1_args,
        tool_2_args
      }
    });
  } catch (error) {
    console.error(`[ERRO] ${error.message}`);
    return jsonResponse({
      error: error.message
    }, 500);
  }
});
