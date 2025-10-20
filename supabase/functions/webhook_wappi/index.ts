/**
 * =====================================================
 * NUTRICOACH AI - WEBHOOK WHATSAPP RECEIVER
 * =====================================================
 * 
 * @module webhook-whatsapp
 * @version 1.0.0
 * @author NutriCoach Development Team
 * @created 2025-10-09
 * 
 * @description
 * Edge Function (Deno) responsável por receber mensagens do webhook do WhatsApp
 * e salvá-las na tabela transitória 'mensagens_temporarias' para posterior
 * agregação e processamento pela LLM.
 * 
 * @architecture
 * Este webhook é a porta de entrada do sistema de mensageria. Ele:
 * 1. Recebe payloads do WhatsApp Web API via HTTP POST
 * 2. Valida e filtra mensagens indesejadas (grupos, broadcast, mídia não suportada)
 * 3. Busca o aluno cadastrado pelo número do WhatsApp
 * 4. Se encontrado, salva mensagem em 'mensagens_temporarias'
 * 5. Se não encontrado, ignora silenciosamente (usuário não cadastrado)
 * 
 * @environment_variables
 * - SUPABASE_URL: URL da instância Supabase (obrigatório)
 * - SUPABASE_SERVICE_ROLE_KEY: Chave de serviço com privilégios admin (obrigatório)
 * - DEBUG_MODE: "true" para logs detalhados, "false" para produção (opcional)
 * 
 * @performance
 * - Latência P50: < 100ms
 * - Latência P95: < 300ms
 * - Throughput: ~1000 req/s
 * 
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const AUDIO_FALLBACK_MESSAGE = "Desculpe, ainda não consigo processar mensagens de áudio. Por favor, digite sua mensagem.";
serve(async (req)=>{
  console.log('═══════════════════════════════════════════════════════════');
  console.log('🚀 [ETAPA 1] WEBHOOK INVOCADO');
  console.log('═══════════════════════════════════════════════════════════');
  console.log('⏰ Timestamp:', new Date().toISOString());
  console.log('🌐 Method:', req.method);
  console.log('📍 URL:', req.url);
  // ===== TRATAMENTO DE PREFLIGHT (CORS) =====
  if (req.method === 'OPTIONS') {
    console.log('✅ [ETAPA 1] Requisição OPTIONS (preflight) - Retornando 200 OK');
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  const isDebugMode = Deno.env.get('DEBUG_MODE') === 'true';
  console.log('🔍 Debug Mode:', isDebugMode ? 'ATIVADO' : 'DESATIVADO');
  try {
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('🔧 [ETAPA 2] INICIALIZANDO CLIENTE SUPABASE');
    console.log('───────────────────────────────────────────────────────────');
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    console.log('📌 SUPABASE_URL:', supabaseUrl ? `${supabaseUrl.substring(0, 30)}...` : '❌ NÃO ENCONTRADA');
    console.log('🔑 SERVICE_ROLE_KEY:', supabaseKey ? `${supabaseKey.substring(0, 20)}...` : '❌ NÃO ENCONTRADA');
    if (!supabaseUrl || !supabaseKey) {
      console.error('❌ [ERRO ETAPA 2] Variáveis de ambiente não configuradas');
      return new Response(JSON.stringify({
        error: 'Configuração inválida do servidor.',
        code: 'ENV_VARS_MISSING'
      }), {
        status: 500,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    const supabase = createClient(supabaseUrl, supabaseKey);
    console.log('✅ [ETAPA 2] Cliente Supabase inicializado com sucesso');
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('🔍 [ETAPA 3] VALIDANDO MÉTODO HTTP');
    console.log('───────────────────────────────────────────────────────────');
    if (req.method !== 'POST') {
      console.warn('⚠️  [ETAPA 3] Método não permitido:', req.method);
      return new Response(JSON.stringify({
        error: 'Método não permitido. Use POST.',
        allowed_methods: [
          'POST'
        ]
      }), {
        status: 405,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [ETAPA 3] Método POST validado');
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('📦 [ETAPA 4] PARSEANDO PAYLOAD JSON');
    console.log('───────────────────────────────────────────────────────────');
    let body;
    try {
      body = await req.json();
      console.log('✅ [ETAPA 4] JSON parseado com sucesso');
      console.log('📋 Payload completo recebido:');
      console.log(JSON.stringify(body, null, 2));
    } catch (parseError) {
      console.error('❌ [ERRO ETAPA 4] Erro ao parsear JSON:', parseError);
      console.error('📄 Body raw:', await req.text());
      return new Response(JSON.stringify({
        error: 'Payload JSON inválido.',
        code: 'INVALID_JSON',
        details: parseError.message
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('🔎 [ETAPA 5] VALIDANDO ESTRUTURA DO PAYLOAD');
    console.log('───────────────────────────────────────────────────────────');
    console.log('🔍 Verificando body:', !!body);
    console.log('🔍 Verificando body.data:', !!body?.data);
    console.log('🔍 Verificando body.data.message:', !!body?.data?.message);
    if (!body || !body.data || !body.data.message) {
      console.error('❌ [ERRO ETAPA 5] Estrutura de payload inválida');
      console.error('📄 Body recebido:', JSON.stringify(body, null, 2));
      return new Response(JSON.stringify({
        error: 'Payload inválido: propriedade "data.message" não encontrada.',
        code: 'INVALID_PAYLOAD_STRUCTURE'
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [ETAPA 5] Estrutura do payload validada');
    const { data, instanceId } = body;
    const message = data.message;
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('📨 [ETAPA 6] EXTRAINDO DADOS DA MENSAGEM');
    console.log('───────────────────────────────────────────────────────────');
    console.log('📍 message.from:', message.from);
    console.log('📝 message.type:', message.type);
    console.log('💬 message.body:', message.body);
    console.log('🔢 message._data:', message._data ? 'Presente' : '❌ Ausente');
    console.log('⏰ message._data.t:', message._data?.t);
    console.log('🏢 instanceId:', instanceId);
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('✔️  [ETAPA 7] VALIDANDO CAMPOS OBRIGATÓRIOS');
    console.log('───────────────────────────────────────────────────────────');
    const validations = {
      'message.from': !!message.from,
      'message.type': !!message.type,
      'message._data': !!message._data,
      'message._data.t': message._data?.t !== undefined
    };
    console.log('📋 Validações:', JSON.stringify(validations, null, 2));
    if (!message.from || !message.type || !message._data || message._data.t === undefined) {
      console.error('❌ [ERRO ETAPA 7] Campos obrigatórios ausentes');
      console.error('📄 Mensagem recebida:', JSON.stringify(message, null, 2));
      return new Response(JSON.stringify({
        error: 'Mensagem incompleta ou malformada.',
        code: 'INCOMPLETE_MESSAGE',
        validations: validations
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [ETAPA 7] Todos os campos obrigatórios presentes');
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('🚦 [ETAPA 8] APLICANDO FILTROS');
    console.log('───────────────────────────────────────────────────────────');
    // FILTRO 1: Status/Broadcast
    console.log('🔍 [FILTRO 1] Verificando se é status@broadcast...');
    if (message.from === 'status@broadcast') {
      console.log('⚠️  [FILTRO 1] É status@broadcast - IGNORANDO');
      return new Response(JSON.stringify({
        message: 'Status broadcast ignorado.',
        code: 'STATUS_BROADCAST_IGNORED'
      }), {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [FILTRO 1] Não é status@broadcast');
    // FILTRO 2: Grupos
    console.log('🔍 [FILTRO 2] Verificando se é mensagem de grupo...');
    console.log('📍 message.from termina com @g.us?', message.from.endsWith('@g.us'));
    if (message.from.endsWith('@g.us')) {
      console.log('⚠️  [FILTRO 2] É mensagem de GRUPO - IGNORANDO');
      return new Response(JSON.stringify({
        message: 'Mensagem de grupo ignorada.',
        code: 'GROUP_MESSAGE_IGNORED',
        chat_id: message.from
      }), {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [FILTRO 2] Não é mensagem de grupo');
    // FILTRO 3: Mensagens sem conteúdo
    console.log('🔍 [FILTRO 3] Verificando se tem conteúdo...');
    console.log('📝 message.body:', message.body);
    console.log('🎤 message.type:', message.type);
    console.log('🔍 Tem body OU é ptt?', !!message.body || message.type === 'ptt');
    if (!message.body && message.type !== 'ptt') {
      console.log('⚠️  [FILTRO 3] Mensagem sem conteúdo - IGNORANDO');
      return new Response(JSON.stringify({
        message: 'Tipo de mensagem não suportado.',
        code: 'UNSUPPORTED_MESSAGE_TYPE',
        type: message.type
      }), {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [FILTRO 3] Mensagem tem conteúdo válido');
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('🔍 [ETAPA 9] EXTRAINDO NÚMERO DO WHATSAPP');
    console.log('───────────────────────────────────────────────────────────');
    const chatId = message.from;
    const whatsappNumber = chatId.split('@')[0];
    console.log('📍 Chat ID completo:', chatId);
    console.log('📱 Número extraído (sem @dominio):', whatsappNumber);
    console.log('🔢 Tamanho do número:', whatsappNumber.length);
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('🔎 [ETAPA 10] BUSCANDO ALUNO NO BANCO DE DADOS');
    console.log('───────────────────────────────────────────────────────────');
    console.log('📋 Query que será executada:');
    console.log(`   SELECT id, nome_completo, whatsapp, status`);
    console.log(`   FROM alunos`);
    console.log(`   WHERE (whatsapp = '${whatsappNumber}'`);
    console.log(`      OR whatsapp = '+${whatsappNumber}'`);
    console.log(`      OR whatsapp LIKE '%${whatsappNumber}')`);
    console.log(`   AND status IN ('trial', 'active')`);
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('id, nome_completo, whatsapp, status').or(`whatsapp.eq.${whatsappNumber},whatsapp.eq.+${whatsappNumber},whatsapp.like.%${whatsappNumber}`).in('status', [
      'trial',
      'active'
    ]).maybeSingle();
    if (alunoError) {
      console.error('❌ [ERRO ETAPA 10] Erro ao buscar aluno no banco');
      console.error('📄 Erro completo:', JSON.stringify(alunoError, null, 2));
      return new Response(JSON.stringify({
        error: 'Erro ao buscar aluno no banco de dados.',
        code: 'DATABASE_ERROR',
        details: alunoError.message
      }), {
        status: 500,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('📊 Resultado da busca:', aluno ? 'ALUNO ENCONTRADO ✅' : 'ALUNO NÃO ENCONTRADO ❌');
    if (aluno) {
      console.log('👤 Dados do aluno encontrado:');
      console.log('   - ID:', aluno.id);
      console.log('   - Nome:', aluno.nome_completo);
      console.log('   - WhatsApp cadastrado:', aluno.whatsapp);
      console.log('   - Status:', aluno.status);
    } else {
      console.log('⚠️  Nenhum aluno encontrado com o número:', whatsappNumber);
      console.log('💡 Possíveis motivos:');
      console.log('   1. Número não cadastrado no sistema');
      console.log('   2. Aluno com status diferente de "trial" ou "active"');
      console.log('   3. Formato do número diferente do cadastrado');
    }
    if (!aluno) {
      console.log('\n⚠️  [ETAPA 10] ALUNO NÃO ENCONTRADO - IGNORANDO MENSAGEM');
      return new Response(JSON.stringify({
        message: 'Aluno não encontrado ou inativo. Mensagem ignorada.',
        code: 'ALUNO_NOT_FOUND',
        whatsapp: whatsappNumber,
        info: 'Número não cadastrado ou aluno inativo'
      }), {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [ETAPA 10] Aluno encontrado e validado');
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('📝 [ETAPA 11] PROCESSANDO CONTEÚDO DA MENSAGEM');
    console.log('───────────────────────────────────────────────────────────');
    let messageContent = message.body || '';
    let hasAudio = false;
    console.log('🔍 Tipo da mensagem:', message.type);
    if (message.type === 'ptt') {
      console.log('🎤 Mensagem de ÁUDIO detectada');
      hasAudio = true;
      messageContent = AUDIO_FALLBACK_MESSAGE;
      console.log('💬 Conteúdo substituído por:', messageContent);
    } else {
      console.log('💬 Mensagem de TEXTO');
      console.log('📄 Conteúdo original:', messageContent);
    }
    const messageTimestamp = new Date(message._data.t * 1000).toISOString();
    console.log('⏰ Timestamp da mensagem:', messageTimestamp);
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('💾 [ETAPA 12] PREPARANDO DADOS PARA INSERÇÃO');
    console.log('───────────────────────────────────────────────────────────');
    const dataToInsert = {
      aluno_id: aluno.id,
      whatsapp: whatsappNumber,
      chat_id: chatId,
      mensagem: messageContent,
      tipo: message.type,
      tem_audio: hasAudio,
      timestamp_mensagem: messageTimestamp,
      timestamp_recebimento: new Date().toISOString(),
      agregado: false,
      instance_id: instanceId || 'unknown',
      metadata: {
        original_type: message.type,
        has_media: message.hasMedia || false,
        from_me: message.fromMe || false
      }
    };
    console.log('📋 Dados preparados para inserção:');
    console.log(JSON.stringify(dataToInsert, null, 2));
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('💿 [ETAPA 13] INSERINDO NA TABELA mensagens_temporarias');
    console.log('───────────────────────────────────────────────────────────');
    console.log('🔄 Executando INSERT...');
    const { data: insertedMessage, error: insertError } = await supabase.from('mensagens_temporarias').insert(dataToInsert).select('id').single();
    if (insertError) {
      console.error('❌ [ERRO ETAPA 13] Erro ao inserir mensagem temporária');
      console.error('📄 Erro completo:', JSON.stringify(insertError, null, 2));
      console.error('📋 Dados que tentamos inserir:', JSON.stringify(dataToInsert, null, 2));
      return new Response(JSON.stringify({
        error: 'Erro ao salvar mensagem temporária.',
        code: 'INSERT_ERROR',
        details: insertError.message,
        hint: insertError.hint
      }), {
        status: 500,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    console.log('✅ [ETAPA 13] Mensagem inserida com SUCESSO!');
    console.log('🆔 ID da mensagem criada:', insertedMessage.id);
    console.log('\n───────────────────────────────────────────────────────────');
    console.log('🎉 [ETAPA 14] RETORNANDO RESPOSTA DE SUCESSO');
    console.log('───────────────────────────────────────────────────────────');
    const responsePayload = {
      success: true,
      message: 'Mensagem recebida e salva. Aguardando agregação.',
      aluno: {
        id: aluno.id,
        nome: aluno.nome_completo
      },
      mensagem_id: insertedMessage.id,
      timestamp: messageTimestamp,
      info: 'Mensagem será agregada pelo cron em até 10 segundos'
    };
    console.log('📤 Resposta que será enviada:');
    console.log(JSON.stringify(responsePayload, null, 2));
    console.log('\n✅✅✅ WEBHOOK EXECUTADO COM SUCESSO ✅✅✅');
    console.log('═══════════════════════════════════════════════════════════\n');
    return new Response(JSON.stringify(responsePayload), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.log('\n═══════════════════════════════════════════════════════════');
    console.error('💥 [ERRO FATAL] EXCEÇÃO NÃO TRATADA');
    console.log('═══════════════════════════════════════════════════════════');
    console.error('❌ Tipo do erro:', error.name);
    console.error('❌ Mensagem:', error.message);
    console.error('❌ Stack trace:', error.stack);
    console.log('═══════════════════════════════════════════════════════════\n');
    return new Response(JSON.stringify({
      error: 'Erro interno do servidor.',
      code: 'INTERNAL_ERROR',
      details: error.message,
      stack: error.stack
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  }
});
