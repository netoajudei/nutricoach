/**
 * @name cron-backup-conversations
 * @version 1.0.0
 * @description Faz backup de todas as conversations antes de deletá-las
 * @schedule 01:00 AM diariamente
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    console.log('[CronBackupConversations] 🚀 Iniciando backup de conversations');
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const ontem = new Date();
    ontem.setDate(ontem.getDate() - 1);
    const dataOntem = ontem.toISOString().split('T')[0];
    // Buscar todos dynamic_prompts com conversation_id
    const { data: prompts, error: promptsError } = await supabase.from('dynamic_prompts').select('aluno_id, conversation_id').not('conversation_id', 'is', null);
    if (promptsError) {
      throw new Error(`Erro ao buscar prompts: ${promptsError.message}`);
    }
    console.log(`[CronBackupConversations] 📊 Total conversations: ${prompts.length}`);
    let processados = 0;
    let backups_salvos = 0;
    let erros = 0;
    for (const prompt of prompts){
      try {
        const { aluno_id, conversation_id } = prompt;
        // Busca nome do aluno (para logs)
        const { data: alunoData } = await supabase.from('alunos').select('nome_completo').eq('id', aluno_id).single();
        const nomeAluno = alunoData?.nome_completo || aluno_id;
        console.log(`[CronBackupConversations] 🔄 ${nomeAluno} - Backup ${conversation_id}`);
        // Busca histórico da OpenAI
        const conversationResponse = await fetch(`https://api.openai.com/v1/conversations/${conversation_id}/items?limit=50`, {
          method: 'GET',
          headers: {
            'Authorization': `Bearer ${OPENAI_API_KEY}`,
            'Content-Type': 'application/json'
          }
        });
        if (!conversationResponse.ok) {
          console.error(`[CronBackupConversations] ⚠️ ${nomeAluno} - OpenAI error ${conversationResponse.status}`);
          erros++;
          processados++;
          continue;
        }
        const conversationData = await conversationResponse.json();
        const totalMensagens = conversationData.data?.length || 0;
        console.log(`[CronBackupConversations] 📊 ${nomeAluno} - ${totalMensagens} mensagens`);
        // Busca métricas do dia anterior
        const { data: metricasData } = await supabase.from('vw_metricas_diarias_por_aluno').select('*').eq('aluno_id', aluno_id).eq('data', dataOntem).single();
        // Salva backup
        const { error: backupError } = await supabase.from('conversation_history').insert({
          aluno_id: aluno_id,
          conversation_id: conversation_id,
          data_conversation: dataOntem,
          conteudo: conversationData,
          total_mensagens: totalMensagens,
          total_chamadas: metricasData?.total_chamadas || null,
          total_input_tokens: metricasData?.total_input_tokens || null,
          total_output_tokens: metricasData?.total_output_tokens || null,
          total_cached_tokens: metricasData?.total_cached_tokens || null,
          input_tokens_faturados: metricasData?.input_tokens_faturados || null,
          gasto_diario_usd: metricasData?.gasto_diario_usd || null
        });
        if (backupError) {
          console.error(`[CronBackupConversations] ❌ ${nomeAluno} - Erro ao salvar: ${backupError.message}`);
          erros++;
        } else {
          console.log(`[CronBackupConversations] ✅ ${nomeAluno} - Backup salvo`);
          // Limpa conversation_id do dynamic_prompts
          const { error: deleteError } = await supabase.from('dynamic_prompts').update({
            conversation_id: null
          }).eq('aluno_id', aluno_id);
          if (deleteError) {
            console.error(`[CronBackupConversations] ⚠️ ${nomeAluno} - Erro ao limpar ID`);
          } else {
            console.log(`[CronBackupConversations] 🗑️ ${nomeAluno} - Conversation_id limpo`);
          }
          backups_salvos++;
        }
        processados++;
      } catch (error) {
        console.error(`[CronBackupConversations] ❌ Erro:`, error.message);
        erros++;
      }
    }
    console.log(`[CronBackupConversations] ✅ CONCLUÍDO`);
    console.log(`[CronBackupConversations] 📊 Processados: ${processados}/${prompts.length}`);
    console.log(`[CronBackupConversations] 💾 Backups salvos: ${backups_salvos}`);
    console.log(`[CronBackupConversations] ❌ Erros: ${erros}`);
    return new Response(JSON.stringify({
      success: true,
      total_conversations: prompts.length,
      processados,
      backups_salvos,
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
    console.error('[CronBackupConversations] ❌ ERRO CRÍTICO:', error.message);
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
