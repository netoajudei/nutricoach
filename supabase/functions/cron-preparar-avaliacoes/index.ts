/**
 * @name cron-preparar-avaliacoes
 * @version 1.0.0
 * @description Prepara dados de conquistas para todos os alunos ativos
 * @schedule 02:00 AM diariamente
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
    console.log('[CronPrepararAvaliacoes] 🚀 Iniciando preparação de avaliações');
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // Buscar todos os alunos ativos
    const { data: alunos, error: alunosError } = await supabase.from('alunos').select('id, nome_completo').eq('subscription_status', 'trial'); // Ajuste conforme seus status
    if (alunosError) {
      throw new Error(`Erro ao buscar alunos: ${alunosError.message}`);
    }
    console.log(`[CronPrepararAvaliacoes] 📊 Total de alunos: ${alunos.length}`);
    let processados = 0;
    let erros = 0;
    // Processar cada aluno
    for (const aluno of alunos){
      try {
        console.log(`[CronPrepararAvaliacoes] 🔄 Processando: ${aluno.nome_completo}`);
        // Chamar função sync_conquistas_recentes
        const { error: syncError } = await supabase.rpc('sync_conquistas_recentes', {
          p_user_id: aluno.id
        });
        if (syncError) {
          console.error(`[CronPrepararAvaliacoes] ❌ Erro em ${aluno.nome_completo}:`, syncError.message);
          erros++;
        } else {
          processados++;
          console.log(`[CronPrepararAvaliacoes] ✅ ${aluno.nome_completo} - OK`);
        }
      } catch (error) {
        console.error(`[CronPrepararAvaliacoes] ❌ Exceção em ${aluno.nome_completo}:`, error.message);
        erros++;
      }
    }
    console.log(`[CronPrepararAvaliacoes] ✅ CONCLUÍDO`);
    console.log(`[CronPrepararAvaliacoes] 📊 Processados: ${processados}/${alunos.length}`);
    console.log(`[CronPrepararAvaliacoes] ❌ Erros: ${erros}`);
    return new Response(JSON.stringify({
      success: true,
      total_alunos: alunos.length,
      processados,
      erros,
      timestamp: new Date().toISOString()
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[CronPrepararAvaliacoes] ❌ ERRO CRÍTICO:', error.message);
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
