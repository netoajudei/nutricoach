/**
 * @name processar-resposta-botao
 * @description
 * Função "Coringa" que recebe um ID de botão (vindo do n8n/WhatsApp Oficial),
 * busca o contexto original no banco e executa a função específica (callback).
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    const { botao_id, confirmado } = await req.json();
    if (!botao_id) {
      throw new Error('Parâmetro "botao_id" é obrigatório.');
    }
    // Cria o cliente Supabase
    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    console.log(`[PROCESSAR-BOTAO] 🔍 Buscando botão: ${botao_id}`);
    // 1. BUSCAR AS INSTRUÇÕES NO BANCO (Exatamente como o webhook fazia)
    const { data: botao, error: botaoErr } = await supabase.from('botoes_ativos').select('edge_function, tipo_acao, argumentos, aluno_id') // Adicionei argumentos/aluno_id por precaução
    .eq('id', botao_id).single();
    if (botaoErr || !botao) {
      console.error('[PROCESSAR-BOTAO] ❌ Botão não encontrado ou já processado.');
      // Retornamos 200 para não travar o WhatsApp/n8n, mas logamos o erro
      return new Response(JSON.stringify({
        error: 'Botão não encontrado'
      }), {
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        },
        status: 200
      });
    }
    console.log(`[PROCESSAR-BOTAO] ✅ Encontrado! Tipo: ${botao.tipo_acao}`);
    console.log(`[PROCESSAR-BOTAO] 🚀 Delegando para: ${botao.edge_function}`);
    // 2. EXECUTAR A FUNÇÃO ESPECÍFICA (A mágica acontece aqui)
    // Passamos o payload EXATO que suas funções atuais esperam.
    const { data: funcData, error: edgeError } = await supabase.functions.invoke(botao.edge_function, {
      body: {
        botao_id: botao_id,
        confirmado: confirmado,
        // Algumas funções antigas podem precisar dos argumentos diretos, 
        // embora geralmente elas busquem no banco de novo. 
        // Passar não faz mal.
        ...botao.argumentos
      }
    });
    if (edgeError) {
      console.error(`[PROCESSAR-BOTAO] ❌ Erro na função ${botao.edge_function}:`, edgeError);
      throw edgeError;
    }
    console.log('[PROCESSAR-BOTAO] ✅ Execução delegada com sucesso.');
    return new Response(JSON.stringify({
      success: true,
      delegated_to: botao.edge_function,
      result: funcData
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[PROCESSAR-BOTAO] ❌ ERRO CRÍTICO:', error.message);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 500
    });
  }
});
