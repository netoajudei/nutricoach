import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
serve(async (req)=>{
  // Handle CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders
    });
  }
  try {
    // Inicializa Supabase client
    const supabaseClient = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
    // Parse request body
    const { codigo, whatsapp } = await req.json();
    console.log(`[Ativar Convite] Código: ${codigo}, WhatsApp: ${whatsapp}`);
    // ========================================
    // 1. BUSCAR CONVITE
    // ========================================
    const { data: convite, error: conviteError } = await supabaseClient.from("convites_alunos").select(`
        id,
        aluno_id,
        profissional_id,
        codigo,
        status,
        expira_em,
        tentativas_uso,
        alunos!convites_alunos_aluno_id_fkey (
          id,
          nome_completo,
          whatsapp
        )
      `).eq("codigo", codigo.toUpperCase().trim()).single();
    if (conviteError || !convite) {
      console.error("[Ativar Convite] Convite não encontrado:", conviteError);
      return new Response(JSON.stringify({
        success: false,
        error: "codigo_invalido",
        message: "Código de convite não encontrado"
      }), {
        status: 404,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    // ========================================
    // 2. VALIDAÇÕES
    // ========================================
    // Verifica se já foi ativado
    if (convite.status === "ativado") {
      console.log("[Ativar Convite] Convite já foi ativado anteriormente");
      return new Response(JSON.stringify({
        success: false,
        error: "convite_ja_ativado",
        message: "Este código já foi utilizado",
        aluno: convite.alunos
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    // Verifica se expirou
    const agora = new Date();
    const expiracao = new Date(convite.expira_em);
    if (agora > expiracao) {
      console.log("[Ativar Convite] Convite expirado");
      // Atualiza status para expirado
      await supabaseClient.from("convites_alunos").update({
        status: "expirado"
      }).eq("id", convite.id);
      return new Response(JSON.stringify({
        success: false,
        error: "convite_expirado",
        message: "Este código expirou. Entre em contato com seu profissional para gerar um novo."
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    // Verifica tentativas de uso (anti-spam)
    if (convite.tentativas_uso >= 5) {
      console.log("[Ativar Convite] Muitas tentativas de uso");
      await supabaseClient.from("convites_alunos").update({
        status: "cancelado"
      }).eq("id", convite.id);
      return new Response(JSON.stringify({
        success: false,
        error: "convite_bloqueado",
        message: "Este código foi bloqueado por segurança. Entre em contato com seu profissional."
      }), {
        status: 403,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    // ========================================
    // 3. VERIFICAR SE WHATSAPP JÁ ESTÁ EM USO
    // ========================================
    const { data: alunoExistente } = await supabaseClient.from("alunos").select("id, nome_completo, whatsapp").eq("whatsapp", whatsapp).single();
    if (alunoExistente && alunoExistente.id !== convite.aluno_id) {
      console.log("[Ativar Convite] WhatsApp já está vinculado a outro aluno");
      // Incrementa tentativas
      await supabaseClient.from("convites_alunos").update({
        tentativas_uso: convite.tentativas_uso + 1
      }).eq("id", convite.id);
      return new Response(JSON.stringify({
        success: false,
        error: "whatsapp_em_uso",
        message: "Este número já está cadastrado para outro aluno"
      }), {
        status: 409,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    // ========================================
    // 4. ATIVAR CONVITE
    // ========================================
    // Atualiza WhatsApp do aluno
    const { error: updateAlunoError } = await supabaseClient.from("alunos").update({
      whatsapp: whatsapp,
      updated_at: new Date().toISOString()
    }).eq("id", convite.aluno_id);
    if (updateAlunoError) {
      console.error("[Ativar Convite] Erro ao atualizar aluno:", updateAlunoError);
      throw updateAlunoError;
    }
    // Atualiza status do convite
    const { error: updateConviteError } = await supabaseClient.from("convites_alunos").update({
      status: "ativado",
      data_ativacao: new Date().toISOString(),
      whatsapp_ativado: whatsapp,
      tentativas_uso: convite.tentativas_uso + 1
    }).eq("id", convite.id);
    if (updateConviteError) {
      console.error("[Ativar Convite] Erro ao atualizar convite:", updateConviteError);
      throw updateConviteError;
    }
    // ========================================
    // 5. SUCESSO
    // ========================================
    console.log(`[Ativar Convite] ✅ Convite ativado com sucesso para aluno: ${convite.alunos.nome_completo}`);
    return new Response(JSON.stringify({
      success: true,
      message: `Bem-vindo(a), ${convite.alunos.nome_completo}! Seu perfil foi ativado com sucesso ✅`,
      aluno: {
        id: convite.aluno_id,
        nome: convite.alunos.nome_completo,
        whatsapp: whatsapp
      }
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  } catch (error) {
    console.error("[Ativar Convite] Erro geral:", error);
    return new Response(JSON.stringify({
      success: false,
      error: "erro_interno",
      message: "Erro ao processar convite. Tente novamente.",
      details: error.message
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
});
