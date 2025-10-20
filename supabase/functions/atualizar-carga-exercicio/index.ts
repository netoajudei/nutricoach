/**
 * @name atualizar-carga-exercicio
 * @version 1.0.0
 * @author NutriCoach AI Development
 * @date 2025-10-16
 *
 * @description
 * Função que atualiza a carga de um exercício no plano do aluno.
 * Acionada quando o aluno clica em "Sim, atualizar!" no botão de confirmação.
 *
 * @workflow
 * 1. Recebe: aluno_id, exercicio_id, nova_carga, whatsapp
 * 2. Busca o exercício na tabela `exercicios` pelo ID
 * 3. Atualiza a carga do exercício
 * 4. Registra a mudança para auditoria
 * 5. Envia confirmação via WhatsApp
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
    const { aluno_id, exercicio_id, nova_carga, whatsapp } = await req.json();
    // ========================================
    // VALIDAÇÕES
    // ========================================
    if (!aluno_id || !exercicio_id || nova_carga === undefined) {
      throw new Error("Dados incompletos: `aluno_id`, `exercicio_id` e `nova_carga` são obrigatórios.");
    }
    console.log('[ATUALIZAR-CARGA] 📊 Iniciando atualização');
    console.log('[ATUALIZAR-CARGA] Aluno ID:', aluno_id);
    console.log('[ATUALIZAR-CARGA] Exercício ID:', exercicio_id);
    console.log('[ATUALIZAR-CARGA] Nova Carga:', nova_carga);
    console.log('[ATUALIZAR-CARGA] WhatsApp:', whatsapp);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // BUSCAR EXERCÍCIO ATUAL
    // ========================================
    console.log('[ATUALIZAR-CARGA] 🔍 Buscando exercício...');
    const { data: exercicio, error: exercicioError } = await supabase.from('exercicios').select('*').eq('id', exercicio_id).eq('aluno_id', aluno_id).single();
    if (exercicioError || !exercicio) {
      console.error('[ATUALIZAR-CARGA] ❌ Exercício não encontrado:', exercicioError?.message);
      throw new Error(`Exercício não encontrado. ID: ${exercicio_id}`);
    }
    console.log('[ATUALIZAR-CARGA] ✅ Exercício encontrado:', exercicio.nome);
    const cargaAtual = exercicio.carga || 0;
    console.log('[ATUALIZAR-CARGA] 📍 Carga atual:', cargaAtual, 'kg');
    // ========================================
    // ATUALIZAR CARGA
    // ========================================
    console.log('[ATUALIZAR-CARGA] 🔄 Atualizando carga...');
    const { data: exercicioAtualizado, error: updateError } = await supabase.from('exercicios').update({
      carga: nova_carga,
      updated_at: new Date().toISOString()
    }).eq('id', exercicio_id).eq('aluno_id', aluno_id).select().single();
    if (updateError) {
      console.error('[ATUALIZAR-CARGA] ❌ Erro ao atualizar:', updateError.message);
      throw new Error(`Erro ao atualizar exercício: ${updateError.message}`);
    }
    console.log('[ATUALIZAR-CARGA] ✅ Exercício atualizado com sucesso');
    console.log('[ATUALIZAR-CARGA] 📊 Nova carga:', exercicioAtualizado.carga, 'kg');
    // ========================================
    // REGISTRAR AUDITORIA
    // ========================================
    console.log('[ATUALIZAR-CARGA] 📝 Registrando auditoria...');
    const { error: auditError } = await supabase.from('historico_atualizacoes_exercicio').insert({
      aluno_id: aluno_id,
      exercicio_id: exercicio_id,
      carga_anterior: cargaAtual,
      carga_nova: nova_carga,
      tipo_mudanca: 'botao_confirmacao',
      timestamp: new Date().toISOString()
    }).catch((err)=>{
      console.warn('[ATUALIZAR-CARGA] ⚠️ Tabela de auditoria pode não existir, mas continuando...');
      return {
        error: null
      };
    });
    if (auditError) {
      console.warn('[ATUALIZAR-CARGA] ⚠️ Erro ao registrar auditoria (não crítico):', auditError.message);
    } else {
      console.log('[ATUALIZAR-CARGA] ✅ Auditoria registrada');
    }
    // ========================================
    // ENVIAR CONFIRMAÇÃO VIA WHATSAPP
    // ========================================
    console.log('[ATUALIZAR-CARGA] 📱 Preparando mensagem de confirmação...');
    const mensagemConfirmacao = `✅ Ótimo! Sua carga foi atualizada com sucesso!

*${exercicio.nome}*
${cargaAtual}kg → *${nova_carga}kg* 💪

Vamos lá! Essa carga extra vai fazer você ficar ainda mais forte nos próximos treinos! 🚀`;
    // Disparar função de envio de mensagem (sem await para não bloquear)
    const presenceUrl = `https://us.api-wa.me/${Deno.env.get('WAME_API_KEY')}/message/text`;
    fetch(presenceUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        to: whatsapp,
        text: mensagemConfirmacao
      })
    }).then((res)=>{
      console.log('[ATUALIZAR-CARGA] ✅ Mensagem de confirmação enviada');
      return res.json();
    }).catch((err)=>{
      console.error('[ATUALIZAR-CARGA] ⚠️ Erro ao enviar mensagem de confirmação:', err.message);
    });
    // ========================================
    // RETORNO
    // ========================================
    console.log('[ATUALIZAR-CARGA] ✨ Processo concluído com sucesso');
    return new Response(JSON.stringify({
      success: true,
      message: `Carga de ${exercicio.nome} atualizada de ${cargaAtual}kg para ${nova_carga}kg`,
      exercicio: {
        id: exercicio_id,
        nome: exercicio.nome,
        carga_anterior: cargaAtual,
        carga_nova: nova_carga
      }
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('🔥 Erro em atualizar-carga-exercicio:', error.message);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: corsHeaders
    });
  }
});
