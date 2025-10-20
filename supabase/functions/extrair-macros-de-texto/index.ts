/**
 * @name extrair-macros-de-texto
 * @version 2.1.0 (Debug)
 * @description
 * Versão de depuração para inspecionar os dados recebidos e enviados para a OpenAI.
 *
 * @changelog
 * - v2.1.0: Adicionados logs detalhados para exibir:
 * 1. O payload exato recebido pela função (`aluno_id` e `texto_alimentos`).
 * 2. O `systemPrompt` e o `userContent` enviados para a OpenAI.
 * 3. O corpo completo da resposta da OpenAI antes de ser processado.
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
    const { texto_alimentos, aluno_id } = await req.json();
    // <<-- LOG 1: VERIFICAR O PAYLOAD RECEBIDO -->>
    console.log("[Extrator-Debug] Payload recebido:", JSON.stringify({
      texto_alimentos,
      aluno_id
    }, null, 2));
    if (!texto_alimentos || !aluno_id) {
      throw new Error('Campos `texto_alimentos` e `aluno_id` são obrigatórios');
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // --- Lógica de chamada à OpenAI (com logs adicionais) ---
    const systemPrompt = "Você é um extrator de dados nutricionais. Analise o texto fornecido e ESTIME os valores totais de macronutrientes. SEMPRE chame a função extrair_macros com os valores totais estimados. Se não conseguir estimar algum valor, use 0.";
    const userContent = texto_alimentos;
    // <<-- LOG 2: VERIFICAR O QUE ESTÁ SENDO ENVIADO PARA A IA -->>
    console.log("[Extrator-Debug] System Prompt:", systemPrompt);
    console.log("[Extrator-Debug] User Content (Resumo):", userContent);
    const tools = [
      {
        type: "function",
        function: {
          name: "extrair_macros",
          parameters: {
            type: "object",
            required: [
              "calorias",
              "carboidratos",
              "proteinas",
              "gorduras"
            ],
            properties: {
              calorias: {
                type: "integer"
              },
              carboidratos: {
                type: "integer"
              },
              proteinas: {
                type: "integer"
              },
              gorduras: {
                type: "integer"
              }
            }
          }
        }
      }
    ];
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        model: "gpt-4.1",
        messages: [
          {
            role: "system",
            content: systemPrompt
          },
          {
            role: "user",
            content: userContent
          }
        ],
        tools: tools,
        tool_choice: {
          type: "function",
          function: {
            name: "extrair_macros"
          }
        }
      })
    });
    const responseBodyText = await response.text();
    if (!response.ok) throw new Error(`Erro na API da OpenAI: ${responseBodyText}`);
    // <<-- LOG 3: VERIFICAR A RESPOSTA BRUTA DA IA -->>
    console.log("[Extrator-Debug] Resposta bruta da OpenAI:", responseBodyText);
    const data = JSON.parse(responseBodyText);
    const macros = JSON.parse(data.choices[0].message.tool_calls[0].function.arguments);
    console.log('[Extrator] Macros extraídos:', macros);
    // ... (lógica para buscar metas e salvar no banco, sem alterações) ...
    const { data: planoAtivo, error: planoError } = await supabase.from('diet_plans').select('meta_diaria_geral').eq('aluno_id', aluno_id).eq('is_active', true).single();
    if (planoError || !planoAtivo) throw new Error(`Nenhum plano de dieta ativo encontrado: ${planoError?.message}`);
    const metasDiarias = planoAtivo.meta_diaria_geral;
    const { error } = await supabase.from('daily_consumption_history').upsert({
      aluno_id: aluno_id,
      data_registro: new Date().toISOString().split('T')[0],
      meta_calorias: metasDiarias.calorias,
      meta_proteina: metasDiarias.proteinas,
      meta_carboidrato: metasDiarias.carboidratos,
      meta_gordura: metasDiarias.gorduras,
      consumo_calorias: macros.calorias,
      consumo_proteina: macros.proteinas,
      consumo_carboidrato: macros.carboidratos,
      consumo_gordura: macros.gorduras
    }, {
      onConflict: 'aluno_id,data_registro'
    });
    if (error) throw new Error(`Erro DB: ${error.message}`);
    console.log('[Extrator] ✅ Salvo!');
    return new Response(JSON.stringify({
      success: true,
      macros: macros
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[Extrator] Erro:', error.message);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  }
});
