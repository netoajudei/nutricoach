import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
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
    if (!texto_alimentos || !aluno_id) {
      throw new Error('Campos obrigatórios faltando');
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
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
            content: "Extraia macronutrientes e chame extrair_macros."
          },
          {
            role: "user",
            content: texto_alimentos
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
    if (!response.ok) throw new Error(await response.text());
    const data = await response.json();
    const macros = JSON.parse(data.choices[0].message.tool_calls[0].function.arguments);
    console.log('[Extrator] Macros:', macros);
    // Agora é SIMPLES! Só as colunas necessárias
    const { error } = await supabase.from('daily_consumption_history').upsert({
      aluno_id: aluno_id,
      data_registro: new Date().toISOString().split('T')[0],
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
      macros: macros,
      resumo: `${macros.calorias} kcal, ${macros.proteinas}g prot, ${macros.carboidratos}g carb, ${macros.gorduras}g gord`
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
