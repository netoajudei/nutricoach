import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  // 1. Handle CORS (Pre-flight)
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    // 2. Receber dados
    const { peso, altura, idade, sexo, nivel_atividade } = await req.json();
    // 3. Validação básica
    if (!peso || !altura || !idade || !sexo) {
      throw new Error("Faltam parâmetros. Envie: peso, altura, idade e sexo.");
    }
    // 4. Cálculo de Mifflin-St Jeor
    // TMB = (10 x peso) + (6.25 x altura) - (5 x idade) + (5 ou -161)
    let tmb = 10 * Number(peso) + 6.25 * Number(altura) - 5 * Number(idade);
    if (sexo.toUpperCase() === 'M') {
      tmb += 5;
    } else if (sexo.toUpperCase() === 'F') {
      tmb -= 161;
    } else {
      throw new Error("Sexo inválido. Use 'M' ou 'F'.");
    }
    // 5. Cálculo do Fator de Atividade (Opcional)
    let gasto_total = null;
    if (nivel_atividade) {
      const fatores = {
        'sedentario': 1.2,
        'leve': 1.375,
        'moderado': 1.55,
        'alto': 1.725,
        'atleta': 1.9
      };
      // Se não achar a chave, usa 1.2 como fallback
      const fator = fatores[nivel_atividade] || 1.2;
      gasto_total = tmb * fator;
    }
    // 6. Resposta
    const data = {
      metabolismo_basal: Math.round(tmb),
      gasto_total_diario: gasto_total ? Math.round(gasto_total) : null,
      info: "Cálculo realizado com sucesso (Acesso Público)"
    };
    return new Response(JSON.stringify(data), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    return new Response(JSON.stringify({
      error: error.message
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 400
    });
  }
});
