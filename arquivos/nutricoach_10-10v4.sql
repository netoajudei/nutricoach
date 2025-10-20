
\restrict 2GfBbM5FdVXzmCFOhF0HupDU0ZPanlg7wkpaBSYcpA8eKTuztrdkdSCwOs6mzEa


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."agregar_mensagens"() RETURNS TABLE("alunos_processados" integer, "mensagens_agregadas" integer, "completions_criados" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
/**
 * @name agregar_mensagens
 * @version 2.4.0
 * @description
 * Esta função agrega mensagens de usuários e aciona o orquestrador.
 * Esta versão retorna a uma lógica mais simples e robusta, preenchendo
 * todos os timestamps necessários.
 */
DECLARE
    v_aluno_record RECORD;
    v_mensagem_concatenada TEXT;
    v_count_msgs INTEGER;
    v_ids_originais UUID[];
    v_nova_mensagem_agregada_id UUID;
    v_alunos_processados INTEGER := 0;
    v_mensagens_agregadas_total INTEGER := 0;
    v_agregacoes_criadas INTEGER := 0;
    v_supabase_url TEXT;
    v_service_key TEXT;
    v_http_request_id BIGINT;
BEGIN
    -- Busca de configurações (sem alteração)
    BEGIN
        SELECT valor INTO v_supabase_url FROM public.config_sistema WHERE chave = 'supabase_url';
        SELECT valor INTO v_service_key FROM public.config_sistema WHERE chave = 'service_role_key';
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Não foi possível buscar configurações do sistema. O orquestrador não será acionado.';
        v_supabase_url := NULL;
        v_service_key := NULL;
    END;

    -- Itera sobre os alunos com mensagens pendentes
    FOR v_aluno_record IN
        SELECT DISTINCT aluno_id, whatsapp, chat_id
        FROM public.mensagens_temporarias
        WHERE agregado = false AND tipo_mensagem = 'RECEBIDA'
    LOOP
        v_alunos_processados := v_alunos_processados + 1;

        -- Coleta e concatena as mensagens
        SELECT array_agg(id), string_agg(mensagem, chr(10) ORDER BY timestamp_recebimento ASC), count(*)
        INTO v_ids_originais, v_mensagem_concatenada, v_count_msgs
        FROM public.mensagens_temporarias
        WHERE aluno_id = v_aluno_record.aluno_id AND agregado = false AND tipo_mensagem = 'RECEBIDA';

        IF v_count_msgs > 0 THEN
            v_mensagens_agregadas_total := v_mensagens_agregadas_total + v_count_msgs;

            -- CRIA A NOVA LINHA AGREGADA - COM A CORREÇÃO
            INSERT INTO public.mensagens_temporarias (
                aluno_id, whatsapp, chat_id, mensagem, tipo, agregado, tipo_mensagem,
                timestamp_mensagem,
                timestamp_agregacao -- <<-- CAMPO CORRIGIDO
            ) VALUES (
                v_aluno_record.aluno_id,
                v_aluno_record.whatsapp,
                v_aluno_record.chat_id,
                v_mensagem_concatenada,
                'text',
                true,
                'AGREGADA_SISTEMA',
                clock_timestamp(), -- Preenche o timestamp da mensagem
                clock_timestamp()  -- Preenche o timestamp da agregação
            ) RETURNING id INTO v_nova_mensagem_agregada_id;

            v_agregacoes_criadas := v_agregacoes_criadas + 1;

            -- ATUALIZA AS MENSAGENS ORIGINAIS
            UPDATE public.mensagens_temporarias
            SET agregado = true,
                timestamp_agregacao = clock_timestamp()
            WHERE id = ANY(v_ids_originais);

            -- ACIONA O ORQUESTRADOR (sem alteração)
            IF v_supabase_url IS NOT NULL AND v_service_key IS NOT NULL AND v_nova_mensagem_agregada_id IS NOT NULL THEN
                BEGIN
                    SELECT net.http_post(
                        url := v_supabase_url || '/functions/v1/orquestrador-ia',
                        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_service_key),
                        body := jsonb_build_object('mensagem_id', v_nova_mensagem_agregada_id)
                    ) INTO v_http_request_id;
                     RAISE NOTICE 'Orquestrador acionado para a mensagem agregada ID: %', v_nova_mensagem_agregada_id;
                EXCEPTION WHEN OTHERS THEN
                    RAISE WARNING 'Falha ao acionar o orquestrador para a mensagem ID: %. Erro: %', v_nova_mensagem_agregada_id, SQLERRM;
                END;
            END IF;
        END IF;
    END LOOP;

    RETURN QUERY SELECT v_alunos_processados, v_mensagens_agregadas_total, v_agregacoes_criadas AS completions_criados;
END;
$$;


ALTER FUNCTION "public"."agregar_mensagens"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."agregar_mensagens_para_aluno"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name agregar_mensagens_para_aluno
 * @description Executa a lógica de agregação para um único aluno.
 * Se houver apenas 1 mensagem, processa diretamente. Se houver mais,
 * cria uma nova entrada agregada.
 */
DECLARE
    v_mensagem_concatenada TEXT;
    v_count_msgs INTEGER;
    v_ids_originais UUID[];
    v_mensagem_para_processar_id UUID;
    v_aluno_record RECORD;
    v_supabase_url TEXT;
    v_service_key TEXT;
BEGIN
    -- ... (busca de configurações)
    BEGIN
        SELECT valor INTO v_supabase_url FROM public.config_sistema WHERE chave = 'supabase_url';
        SELECT valor INTO v_service_key FROM public.config_sistema WHERE chave = 'service_role_key';
    EXCEPTION WHEN OTHERS THEN v_supabase_url := NULL; v_service_key := NULL; END;

    -- Busca dados do aluno
    SELECT id, whatsapp INTO v_aluno_record FROM public.alunos WHERE id = p_aluno_id;

    -- Busca e AGREGA as mensagens pendentes, e o mais importante, CONTA quantas são
    SELECT array_agg(mt.id), string_agg(mt.mensagem, chr(10) ORDER BY mt.timestamp_recebimento ASC), count(mt.id)
    INTO v_ids_originais, v_mensagem_concatenada, v_count_msgs
    FROM public.mensagens_temporarias mt
    WHERE mt.aluno_id = p_aluno_id AND mt.agregado = false AND mt.tipo_mensagem = 'RECEBIDA';
    
    -- <<-- INÍCIO DA LÓGICA INTELIGENTE QUE VOCÊ PEDIU -->>
    IF v_count_msgs = 1 THEN
        -- Se há UMA mensagem, não cria nada novo.
        -- Apenas pega o ID da mensagem original para enviar ao orquestrador.
        RAISE NOTICE '[Agregador] 1 mensagem encontrada. Processando diretamente.';
        v_mensagem_para_processar_id := v_ids_originais[1];
        UPDATE public.mensagens_temporarias SET agregado = true WHERE id = v_mensagem_para_processar_id;

    ELSIF v_count_msgs > 1 THEN
        -- Se há MAIS DE UMA, executa o processo completo de agregação.
        RAISE NOTICE '[Agregador] % mensagens encontradas. Criando nova linha agregada.', v_count_msgs;
        
        -- Pega o chat_id (necessário para o INSERT)
        SELECT chat_id INTO v_aluno_record.chat_id FROM public.mensagens_temporarias WHERE id = v_ids_originais[1];

        INSERT INTO public.mensagens_temporarias (
            aluno_id, whatsapp, chat_id, mensagem, tipo, agregado, tipo_mensagem,
            timestamp_mensagem, timestamp_agregacao
        ) VALUES (
            p_aluno_id, v_aluno_record.whatsapp, v_aluno_record.chat_id, v_mensagem_concatenada,
            'text', true, 'AGREGADA_SISTEMA', clock_timestamp(), clock_timestamp()
        ) RETURNING id INTO v_mensagem_para_processar_id;
        
        UPDATE public.mensagens_temporarias SET agregado = true WHERE id = ANY(v_ids_originais);
    END IF;
    -- <<-- FIM DA LÓGICA INTELIGENTE -->>

    -- Aciona o orquestrador com o ID da mensagem final (seja a original ou a nova agregada)
    IF v_supabase_url IS NOT NULL AND v_service_key IS NOT NULL AND v_mensagem_para_processar_id IS NOT NULL THEN
        PERFORM net.http_post(
            url := v_supabase_url || '/functions/v1/orquestrador-ia',
            headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_service_key),
            body := jsonb_build_object('mensagem_id', v_mensagem_para_processar_id)
        );
    END IF;
END;
$$;


ALTER FUNCTION "public"."agregar_mensagens_para_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_exercicio RECORD;
  v_carga_anterior NUMERIC;
  v_nome_exercicio VARCHAR;
  v_resultado JSON;
BEGIN
  -- ========================================
  -- VALIDAÇÕES
  -- ========================================
  IF p_exercicio_id IS NULL OR p_aluno_id IS NULL OR p_nova_carga IS NULL THEN
    RAISE EXCEPTION 'Parâmetros obrigatórios faltando: exercicio_id, aluno_id, nova_carga';
  END IF;

  -- ========================================
  -- BUSCAR EXERCÍCIO COM VALIDAÇÃO
  -- ========================================
  -- Precisamos verificar que o exercício pertence ao aluno
  -- Através da hierarquia: alunos → workout_programs → program_workouts → workout_exercises
  
  SELECT 
    we.id,
    we.nome_exercicio,
    we.carga_kg,
    we.workout_id,
    pw.program_id,
    wp.aluno_id
  INTO v_exercicio
  FROM workout_exercises we
  JOIN program_workouts pw ON we.workout_id = pw.id
  JOIN workout_programs wp ON pw.program_id = wp.id
  WHERE we.id = p_exercicio_id
  AND wp.aluno_id = p_aluno_id;

  -- Verificar se exercício existe e pertence ao aluno
  IF v_exercicio IS NULL THEN
    RAISE EXCEPTION 'Exercício não encontrado ou não pertence a este aluno. ID: %', p_exercicio_id;
  END IF;

  v_carga_anterior := v_exercicio.carga_kg;
  v_nome_exercicio := v_exercicio.nome_exercicio;

  -- ========================================
  -- ATUALIZAR CARGA
  -- ========================================
  UPDATE workout_exercises
  SET 
    carga_kg = p_nova_carga
  WHERE id = p_exercicio_id;

  -- ========================================
  -- REGISTRAR AUDITORIA
  -- ========================================
  -- Assumindo que existe tabela: historico_atualizacoes_exercicio
  -- Se não existir, cria dinamicamente (opcional)
  
  INSERT INTO historico_atualizacoes_exercicio (
    aluno_id,
    exercicio_id,
    carga_anterior,
    carga_nova,
    tipo_mudanca,
    timestamp
  ) VALUES (
    p_aluno_id,
    p_exercicio_id,
    v_carga_anterior,
    p_nova_carga,
    'botao_confirmacao_whatsapp',
    NOW()
  );

  -- ========================================
  -- PREPARAR RETORNO
  -- ========================================
  v_resultado := json_build_object(
    'success', true,
    'message', format('Carga de %s atualizada com sucesso', v_nome_exercicio),
    'exercicio', json_build_object(
      'id', p_exercicio_id,
      'nome', v_nome_exercicio,
      'carga_anterior', v_carga_anterior,
      'carga_nova', p_nova_carga,
      'whatsapp', p_whatsapp
    )
  );

  RETURN v_resultado;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Erro ao atualizar carga: %', SQLERRM;

END;
$$;


ALTER FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name atualizar_prompt_final_para_aluno
 * @version 1.0.0
 * @description
 * Força a reconstrução do prompt de sistema completo para um aluno específico.
 * Esta função lê todas as colunas de contexto da tabela `dynamic_prompts`
 * e as concatena na coluna `prompt_final`.
 *
 * @param {UUID} p_aluno_id - O ID do aluno cujo prompt será atualizado.
 * @returns {TEXT} Uma mensagem de confirmação.
 */
DECLARE
    v_prompt_record RECORD;
    v_prompt_final_text TEXT;
BEGIN
    RAISE NOTICE '[Atualizador Manual] Iniciando a reconstrução do prompt para o aluno ID: %', p_aluno_id;

    -- 1. Busca todos os blocos de contexto da tabela dynamic_prompts
    SELECT * INTO v_prompt_record
    FROM public.dynamic_prompts
    WHERE aluno_id = p_aluno_id;

    IF NOT FOUND THEN
        RAISE WARNING '[Atualizador Manual] Nenhum registro encontrado em dynamic_prompts para o aluno ID: %', p_aluno_id;
        RETURN 'ERRO: Aluno não encontrado em dynamic_prompts.';
    END IF;

    -- 2. Concatena todos os blocos para formar o prompt final
    v_prompt_final_text := CONCAT(
        COALESCE(v_prompt_record.prompt_base, ''),
        E'\n\n---\n\n# CAMADA 2: CONTEXTO DINÂMICO DO ALUNO\n\n',
        '## SAÚDE E ROTINA:', E'\n', COALESCE(v_prompt_record.saude_e_rotina_json::text, '{}'), E'\n\n',
        '## OBJETIVO ATIVO E PROGRESSO:', E'\n', COALESCE(v_prompt_record.objetivo_ativo_json::text, '{}'), E'\n\n',
        '## PLANO ALIMENTAR E PREFERÊNCIAS:', E'\n', COALESCE(v_prompt_record.plano_alimentar_json::text, '{}'), E'\n\n',
        '## PLANO DE TREINO (PROGRAMA SEMANAL):', E'\n', COALESCE(v_prompt_record.plano_treino_json::text, '{}'), E'\n\n',
        '## CONQUISTAS RECENTES:', E'\n', COALESCE(v_prompt_record.conquistas_recentes_json::text, '[]'), E'\n\n',
        '## INSTRUÇÕES DO NUTRICIONISTA:', E'\n', COALESCE(v_prompt_record.instrucoes_nutricionista_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## INSTRUÇÕES DO PERSONAL TRAINER:', E'\n', COALESCE(v_prompt_record.instrucoes_personal_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## CONSIDERAÇÕES FINAIS:', E'\n', COALESCE(v_prompt_record.consideracoes_finais_text, 'Seja sempre motivador e baseie-se nos dados para fornecer a melhor orientação possível.')
    );

    -- 3. Atualiza a coluna prompt_final com o texto recém-criado
    UPDATE public.dynamic_prompts
    SET prompt_final = v_prompt_final_text
    WHERE aluno_id = p_aluno_id;

    RAISE NOTICE '[Atualizador Manual] ✅ Prompt final para o aluno ID: % foi atualizado com sucesso.', p_aluno_id;
    RETURN 'Prompt final atualizado com sucesso.';
END;
$$;


ALTER FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_old_processed_messages"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  DELETE FROM processed_webhook_messages
  WHERE processed_at < NOW() - INTERVAL '7 days';
END;
$$;


ALTER FUNCTION "public"."cleanup_old_processed_messages"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") RETURNS TABLE("status_code" integer, "response_body" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_supabase_url TEXT;
    v_service_key TEXT;
    v_request_id BIGINT;
    v_status INT;
    v_response TEXT;
BEGIN
    -- Busca credenciais
    SELECT valor INTO v_supabase_url FROM config_sistema WHERE chave = 'supabase_url';
    SELECT valor INTO v_service_key FROM config_sistema WHERE chave = 'service_role_key';
    
    RAISE NOTICE '[Extrator] Aluno: %, Texto: %', p_aluno_id, LEFT(p_texto_alimentos, 100);
    
    -- Faz requisição
    SELECT INTO v_request_id net.http_post(
        url := v_supabase_url || '/functions/v1/testar-extracao',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_key
        ),
        body := jsonb_build_object(
            'texto_alimentos', p_texto_alimentos,
            'aluno_id', p_aluno_id
        ),
        timeout_milliseconds := 30000
    );
    
    RAISE NOTICE '[Extrator] Request ID: %', v_request_id;
    
    -- Aguarda
    PERFORM pg_sleep(5);
    
    -- Busca resultado
    SELECT r.status_code, r.content::TEXT
    INTO v_status, v_response
    FROM net._http_response r
    WHERE r.id = v_request_id;
    
    RAISE NOTICE '[Extrator] Status: %, Response: %', v_status, LEFT(v_response, 200);
    
    RETURN QUERY SELECT v_status, v_response;
END;
$$;


ALTER FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_metricas_recentes RECORD;
    v_progresso_peso NUMERIC;
BEGIN
    RAISE NOTICE 'Iniciando análise de conquistas para o aluno ID: %', p_aluno_id;

    -- ===============================================================
    -- CONQUISTA 1: Perda de Peso
    -- Verifica se o peso na última medição é menor que o da penúltima.
    -- ===============================================================
    -- Busca as duas últimas medições de peso
    SELECT
        (SELECT peso_kg FROM public.body_metrics WHERE aluno_id = p_aluno_id ORDER BY data_medicao DESC LIMIT 1) as peso_atual,
        (SELECT peso_kg FROM public.body_metrics WHERE aluno_id = p_aluno_id ORDER BY data_medicao DESC LIMIT 1 OFFSET 1) as peso_anterior
    INTO v_metricas_recentes;

    -- Se tivermos as duas medições para comparar
    IF v_metricas_recentes.peso_atual IS NOT NULL AND v_metricas_recentes.peso_anterior IS NOT NULL THEN
        IF v_metricas_recentes.peso_atual < v_metricas_recentes.peso_anterior THEN
            v_progresso_peso := v_metricas_recentes.peso_anterior - v_metricas_recentes.peso_atual;
            RAISE NOTICE ' -> Progresso de peso detectado: % kg', v_progresso_peso;

            -- Evita duplicatas: só insere se uma conquista de perda de peso não foi dada nos últimos 7 dias
            IF NOT EXISTS (
                SELECT 1 FROM public.achievements
                WHERE aluno_id = p_aluno_id
                  AND categoria = 'PESO'
                  AND data_conquista >= CURRENT_DATE - INTERVAL '7 days'
            ) THEN
                RAISE NOTICE ' -> Inserindo nova conquista de perda de peso!';
                INSERT INTO public.achievements (aluno_id, titulo, categoria, descricao)
                VALUES (
                    p_aluno_id,
                    'Parabéns! Você eliminou ' || ROUND(v_progresso_peso, 1) || ' kg!',
                    'PESO',
                    'Seu peso reduziu de ' || v_metricas_recentes.peso_anterior || 'kg para ' || v_metricas_recentes.peso_atual || 'kg. Continue assim!'
                );
            END IF;
        END IF;
    END IF;

    -- ===============================================================
    -- CONQUISTA 2: Aderência ao Treino (Exemplo - depende dos logs)
    -- Futuramente, esta parte analisaria a tabela `daily_workout_logs`.
    -- ===============================================================
    -- (Lógica a ser implementada quando tivermos os logs diários)
    -- Exemplo: Se o aluno treinou 100% dos dias planejados na semana,
    -- inserir uma conquista de "Semana de treinos perfeita!".


    RAISE NOTICE 'Análise de conquistas concluída.';
END;
$$;


ALTER FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") IS 'Analisa o progresso recente de um aluno (peso, treinos, dieta) e insere novos registros na tabela `achievements` se marcos forem atingidos.';



CREATE OR REPLACE FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_dia_semana TEXT;
BEGIN
    -- Converte o número do dia da semana para o texto usado no JSON
    v_dia_semana := CASE EXTRACT(DOW FROM CURRENT_DATE)
        WHEN 0 THEN 'domingo'
        WHEN 1 THEN 'segunda-feira'
        WHEN 2 THEN 'terca-feira'
        WHEN 3 THEN 'quarta-feira'
        WHEN 4 THEN 'quinta-feira'
        WHEN 5 THEN 'sexta-feira'
        WHEN 6 THEN 'sabado'
    END;

    -- Retorna o plano para o dia específico, ou o plano padrão, ou um JSON vazio.
    RETURN COALESCE(
        p_plano_semanal -> v_dia_semana,
        p_plano_semanal -> 'default_day',
        '{}'::jsonb
    );
END;
$$;


ALTER FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") IS 'Função auxiliar que extrai o plano de refeições do dia corrente de um JSONB de plano semanal.';



CREATE OR REPLACE FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
/**
 * @name get_full_workout_program_json
 * @changelog v1.1: Adicionado o campo 'id' ao objeto JSON de cada
 * exercício, extraído diretamente da tabela `workout_exercises`.
 */
DECLARE
    v_program_json JSONB;
BEGIN
    -- Constrói um objeto JSON onde cada chave é o dia da semana
    -- e o valor é o objeto do treino daquele dia.
    SELECT
        jsonb_object_agg(
            pw.dia_da_semana,
            jsonb_build_object(
                'nome_treino', pw.nome_treino,
                'exercicios', (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            -- <<-- ALTERAÇÃO AQUI -->>
                            'id', we.id, -- Adiciona o ID do exercício ao JSON
                            'ordem', we.ordem,
                            'nome', we.nome_exercicio,
                            'series', we.series,
                            'repeticoes', we.repeticoes,
                            'carga_atual_kg', we.carga_kg,
                            'descanso_seg', we.descanso_segundos
                        ) ORDER BY we.ordem
                    )
                    FROM public.workout_exercises AS we
                    WHERE we.workout_id = pw.id
                )
            )
        )
    INTO v_program_json
    FROM public.program_workouts AS pw
    WHERE pw.program_id = p_program_id;

    RETURN COALESCE(v_program_json, '{}'::jsonb);
END;
$$;


ALTER FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") IS 'Função auxiliar que busca TODOS os treinos e exercícios de um programa e os formata em um único objeto JSON representando a semana completa.';



CREATE OR REPLACE FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_dia_semana SMALLINT;
    v_workout_json JSONB;
BEGIN
    -- Obtém o dia da semana (0=Domingo, 1=Segunda, ..., 6=Sábado)
    v_dia_semana := EXTRACT(DOW FROM CURRENT_DATE);

    -- Constrói o JSON para o treino de hoje
    SELECT
        jsonb_build_object(
            'nome_treino', pw.nome_treino,
            'exercicios', (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'ordem', we.ordem,
                        'nome', we.nome_exercicio,
                        'series', we.series,
                        'repeticoes', we.repeticoes,
                        'carga_atual_kg', we.carga_kg,
                        'descanso_seg', we.descanso_segundos
                    ) ORDER BY we.ordem
                )
                FROM public.workout_exercises AS we
                WHERE we.workout_id = pw.id
            )
        )
    INTO v_workout_json
    FROM public.program_workouts AS pw
    WHERE pw.program_id = p_program_id AND pw.dia_da_semana = v_dia_semana;

    -- Se não houver treino para hoje, retorna um objeto de descanso.
    RETURN COALESCE(v_workout_json, '{"nome_treino": "Descanso"}'::jsonb);
END;
$$;


ALTER FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") IS 'Função auxiliar que busca os exercícios do dia corrente e os formata em um objeto JSON.';



CREATE OR REPLACE FUNCTION "public"."handle_dynamic_prompt_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_aluno_id UUID;
BEGIN
    -- Determina o aluno_id com base na operação e na tabela
    IF TG_TABLE_NAME IN ('alunos', 'saude_e_rotina', 'goals', 'body_metrics', 'diet_plans', 'preferencias_alimentares', 'preferencias_treino', 'workout_programs', 'achievements') THEN
        v_aluno_id := COALESCE(NEW.aluno_id, OLD.aluno_id);
    ELSIF TG_TABLE_NAME = 'program_workouts' THEN
        SELECT wp.aluno_id INTO v_aluno_id FROM public.workout_programs wp WHERE wp.id = COALESCE(NEW.program_id, OLD.program_id);
    ELSIF TG_TABLE_NAME = 'workout_exercises' THEN
        SELECT wp.aluno_id INTO v_aluno_id
        FROM public.workout_programs wp
        JOIN public.program_workouts pw ON pw.program_id = wp.id
        WHERE pw.id = COALESCE(NEW.workout_id, OLD.workout_id);
    END IF;

    IF v_aluno_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    
    -- Decide qual função de rebuild chamar
    CASE TG_TABLE_NAME
        WHEN 'saude_e_rotina' THEN
            PERFORM public.rebuild_saude_e_rotina_json(v_aluno_id);
        WHEN 'goals', 'body_metrics' THEN
            PERFORM public.rebuild_objetivo_ativo_json(v_aluno_id);
        WHEN 'diet_plans', 'preferencias_alimentares' THEN
            PERFORM public.rebuild_plano_alimentar_json(v_aluno_id);
        WHEN 'workout_programs', 'program_workouts', 'workout_exercises', 'preferencias_treino' THEN
            PERFORM public.rebuild_plano_treino_json(v_aluno_id);
            
        -- NOVA LÓGICA ADICIONADA:
        WHEN 'achievements' THEN
            PERFORM public.rebuild_conquistas_recentes_json(v_aluno_id);
            
        ELSE
            RAISE WARNING '[TRIGGER_MANAGER] Acionado para uma tabela não gerenciada: %', TG_TABLE_NAME;
    END CASE;

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."handle_dynamic_prompt_update"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."handle_dynamic_prompt_update"() IS 'Função de gatilho principal. VERSÃO FINAL, incluindo a lógica para todas as tabelas dinâmicas.';



CREATE OR REPLACE FUNCTION "public"."invoke_testar_extracao_edge_function"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_supabase_url TEXT;
    v_service_key TEXT;
    v_request_id BIGINT;
BEGIN
    RAISE NOTICE '[CRON] Buscando credenciais da tabela config_sistema...';
    
    -- Busca da tabela config_sistema
    SELECT valor INTO v_supabase_url 
    FROM public.config_sistema 
    WHERE chave = 'supabase_url';
    
    SELECT valor INTO v_service_key 
    FROM public.config_sistema 
    WHERE chave = 'service_role_key';
    
    -- Valida se encontrou
    IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
        RAISE WARNING '[CRON] ❌ Credenciais não encontradas na config_sistema!';
        RETURN 'ERRO: Credenciais não configuradas';
    END IF;
    
    RAISE NOTICE '[CRON] ✅ Credenciais encontradas. Chamando Edge Function...';
    
    -- Faz a requisição
    SELECT INTO v_request_id net.http_post(
        url := v_supabase_url || '/functions/v1/testar-extracao',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_key
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 60000
    );

    RAISE NOTICE '[CRON] ✅ Request enviado! ID: %', v_request_id;
    RETURN 'Request ID: ' || v_request_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '[CRON] ❌ Erro: %', SQLERRM;
        RETURN 'ERRO: ' || SQLERRM;
END;
$$;


ALTER FUNCTION "public"."invoke_testar_extracao_edge_function"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."limpar_completions_antigos"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    linhas_deletadas INTEGER;
BEGIN
    DELETE FROM completions
    WHERE created_at < NOW() - INTERVAL '90 days';
    
    GET DIAGNOSTICS linhas_deletadas = ROW_COUNT;
    RAISE NOTICE 'Limpeza completions: % registros deletados', linhas_deletadas;
    RETURN linhas_deletadas;
END;
$$;


ALTER FUNCTION "public"."limpar_completions_antigos"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."limpar_completions_antigos"() IS 'Remove completions com mais de 90 dias.';



CREATE OR REPLACE FUNCTION "public"."limpar_mensagens_temporarias"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    linhas_deletadas INTEGER;
BEGIN
    DELETE FROM mensagens_temporarias
    WHERE agregado = true
      AND timestamp_agregacao < NOW() - INTERVAL '24 hours';
    
    GET DIAGNOSTICS linhas_deletadas = ROW_COUNT;
    RAISE NOTICE 'Limpeza mensagens: % registros deletados', linhas_deletadas;
    RETURN linhas_deletadas;
END;
$$;


ALTER FUNCTION "public"."limpar_mensagens_temporarias"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."limpar_mensagens_temporarias"() IS 'Remove mensagens agregadas há mais de 24h.';



CREATE OR REPLACE FUNCTION "public"."obter_resumo_diario"("p_aluno_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name obter_resumo_diario
 * @changelog v1.3: Adicionado o preenchimento da coluna `tipo`
 * no INSERT para evitar o erro de violação de constraint NOT NULL.
 */
DECLARE
    v_supabase_url TEXT;
    v_service_key TEXT;
    v_mensagem_id UUID;
    v_resumo TEXT;
    v_aluno_whatsapp TEXT;
BEGIN
    RAISE NOTICE '[Resumo Diário] Iniciando para o aluno ID: %', p_aluno_id;

    -- Busca o whatsapp do aluno
    SELECT whatsapp INTO v_aluno_whatsapp
    FROM public.alunos
    WHERE id = p_aluno_id;

    IF NOT FOUND THEN
        RAISE WARNING '[Resumo Diário] Aluno com ID % não encontrado.', p_aluno_id;
        RETURN NULL;
    END IF;

    -- Busca credenciais
    SELECT valor INTO v_supabase_url FROM config_sistema WHERE chave = 'supabase_url';
    SELECT valor INTO v_service_key FROM config_sistema WHERE chave = 'service_role_key';
    IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
        RAISE EXCEPTION '[Resumo Diário] Credenciais não configuradas.';
    END IF;

    -- Cria a "mensagem fantasma" com todos os campos obrigatórios
    INSERT INTO public.mensagens_temporarias (
        aluno_id,
        whatsapp,
        chat_id,
        mensagem,
        timestamp_mensagem,
        tipo_mensagem,
        agregado,
        tipo -- <<-- CAMPO ADICIONADO AQUI
    )
    VALUES (
        p_aluno_id,
        v_aluno_whatsapp,
        v_aluno_whatsapp || '@c.us',
        'Liste em texto puro todos os alimentos e bebidas que eu consumi hoje com as respectivas quantidades em gramas ou ml. Não adicione nenhuma frase de introdução ou conclusão, apenas a lista.',
        NOW(),
        'SISTEMA_INTERNO',
        true,
        'text' -- <<-- VALOR ADICIONADO AQUI
    )
    RETURNING id INTO v_mensagem_id;
    RAISE NOTICE '[Resumo Diário] Mensagem "fantasma" criada com ID: %', v_mensagem_id;

    -- Chama o orquestrador
    PERFORM net.http_post(
        url := v_supabase_url || '/functions/v1/orquestrador-ia',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_service_key),
        body := jsonb_build_object('mensagem_id', v_mensagem_id, 'nao_comunicar_aluno', true)
    );
    RAISE NOTICE '[Resumo Diário] Orquestrador acionado. Aguardando processamento...';

    -- Aguarda e coleta a resposta
    PERFORM pg_sleep(8);
    SELECT resposta INTO v_resumo FROM public.mensagens_temporarias WHERE id = v_mensagem_id;

    IF v_resumo IS NULL OR v_resumo = '' THEN
        RAISE WARNING '[Resumo Diário] A IA não retornou um resumo para a mensagem ID: %', v_mensagem_id;
    ELSE
        RAISE NOTICE '[Resumo Diário] Resumo textual obtido com sucesso.';
    END IF;

    RETURN v_resumo;
END;
$$;


ALTER FUNCTION "public"."obter_resumo_diario"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."processar_confirmacao_refeicao"("p_registro_id" "uuid", "p_confirmar" boolean) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_resultado JSON;
  v_whatsapp TEXT;
BEGIN
  RAISE NOTICE '[Processar Confirmação] Iniciando. Registro ID: %, Confirmar: %', p_registro_id, p_confirmar;

  IF p_confirmar = TRUE THEN
    -- ========================================
    -- CONFIRMAR: Atualiza confirmada = TRUE
    -- ========================================
    RAISE NOTICE '[Processar Confirmação] ✅ Confirmando refeição...';
    
    UPDATE daily_consumption_history
    SET confirmada = TRUE,
        analise_qualitativa = 'Confirmado pelo usuário'
    WHERE id = p_registro_id
    RETURNING (SELECT whatsapp FROM alunos WHERE id = daily_consumption_history.aluno_id) INTO v_whatsapp;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Registro não encontrado. ID: %', p_registro_id;
    END IF;

    v_resultado := json_build_object(
      'success', TRUE,
      'action', 'confirmed',
      'registro_id', p_registro_id,
      'message', 'Refeição confirmada com sucesso'
    );

    RAISE NOTICE '[Processar Confirmação] ✅ Refeição confirmada!';

  ELSE
    -- ========================================
    -- CANCELAR: Deleta o registro
    -- ========================================
    RAISE NOTICE '[Processar Confirmação] 🗑️ Deletando registro...';
    
    DELETE FROM daily_consumption_history
    WHERE id = p_registro_id
    RETURNING (SELECT whatsapp FROM alunos WHERE id = daily_consumption_history.aluno_id) INTO v_whatsapp;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Registro não encontrado. ID: %', p_registro_id;
    END IF;

    v_resultado := json_build_object(
      'success', TRUE,
      'action', 'deleted',
      'registro_id', p_registro_id,
      'message', 'Registro deletado com sucesso'
    );

    RAISE NOTICE '[Processar Confirmação] 🗑️ Registro deletado!';

  END IF;

  RETURN v_resultado;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Erro ao processar confirmação: %', SQLERRM;
END;
$$;


ALTER FUNCTION "public"."processar_confirmacao_refeicao"("p_registro_id" "uuid", "p_confirmar" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."processar_macros_diarios_para_aluno"("p_aluno_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name processar_macros_diarios_para_aluno
 * @version 1.1.0
 * @description
 * Orquestra o processo noturno completo de consolidação de consumo para
 * um único aluno. Esta função é projetada para ser chamada por um
 * agendador como o pg_cron ou manualmente para testes.
 *
 * @param {UUID} p_aluno_id - O ID do aluno a ser processado.
 * @returns {TEXT} Um resumo do resultado da operação.
 */
DECLARE
    v_resumo_diario TEXT;
    v_resultado_extracao RECORD;
BEGIN
    RAISE NOTICE '[Processo Noturno] Iniciando para o aluno: %', p_aluno_id;
    
    -- ETAPA 1: Obter o resumo textual do consumo do dia.
    -- Chama a função que cria a "mensagem fantasma" e usa o orquestrador-ia.
    v_resumo_diario := public.obter_resumo_diario(p_aluno_id);
    
    IF v_resumo_diario IS NULL OR v_resumo_diario = '' THEN
        RAISE WARNING '[Processo Noturno] Não foi possível obter o resumo de consumo para %. Processo encerrado para este aluno.', p_aluno_id;
        RETURN 'Falha: Resumo de consumo não foi gerado.';
    END IF;
    
    RAISE NOTICE '[Processo Noturno] Resumo obtido, acionando extrator de macros...';
    
    -- ETAPA 2: Chamar a função que invoca a Edge Function `extrair-macros-de-texto`.
    -- A própria Edge Function já se encarrega de salvar o resultado no banco.
    SELECT * INTO v_resultado_extracao
    FROM public.extrair_macros_do_texto(v_resumo_diario, p_aluno_id);
    
    IF v_resultado_extracao.status_code = 200 THEN
        RAISE NOTICE '[Processo Noturno] ✅ Processo para o aluno % concluído com sucesso.', p_aluno_id;
        RETURN 'Sucesso: Macros extraídos e salvos. Resposta do extrator: ' || v_resultado_extracao.response_body;
    ELSE
        RAISE WARNING '[Processo Noturno] ❌ Falha na etapa de extração para o aluno %. Status: %, Resposta: %', p_aluno_id, v_resultado_extracao.status_code, v_resultado_extracao.response_body;
        RETURN 'Falha: Erro na etapa de extração de macros.';
    END IF;

END;
$$;


ALTER FUNCTION "public"."processar_macros_diarios_para_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propor_atualizacao_carga"("p_exercicio_id" "uuid", "p_variacao_kg" numeric) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_exercicio RECORD;
  v_carga_atual NUMERIC;
  v_nova_carga NUMERIC;
  v_nome_exercicio VARCHAR;
  v_aluno_id UUID;
  v_whatsapp VARCHAR;
  v_mensagem_texto TEXT;
  v_payload_sim TEXT;
  v_payload_nao TEXT;
  v_api_key VARCHAR;
  v_api_url TEXT;
  v_request_body JSONB;
  v_resultado JSON;
BEGIN
  -- ========================================
  -- LOG DE AUDITORIA - RASTREAR CHAMADAS
  -- ========================================
  INSERT INTO logs_funcoes (
    nome_funcao,
    parametros,
    timestamp,
    status
  ) VALUES (
    'propor_atualizacao_carga',
    jsonb_build_object(
      'exercicio_id', p_exercicio_id,
      'variacao_kg', p_variacao_kg
    ),
    NOW(),
    'iniciado'
  );

  -- ========================================
  -- VALIDAÇÕES
  -- ========================================
  IF p_exercicio_id IS NULL OR p_variacao_kg IS NULL THEN
    RAISE EXCEPTION 'Parâmetros obrigatórios: exercicio_id e variacao_kg';
  END IF;

  -- ========================================
  -- BUSCAR EXERCÍCIO COM DADOS DO ALUNO
  -- ========================================
  SELECT 
    we.id,
    we.nome_exercicio,
    we.carga_kg,
    wp.aluno_id,
    a.whatsapp
  INTO v_exercicio
  FROM workout_exercises we
  JOIN program_workouts pw ON we.workout_id = pw.id
  JOIN workout_programs wp ON pw.program_id = wp.id
  JOIN alunos a ON wp.aluno_id = a.id
  WHERE we.id = p_exercicio_id
  AND wp.is_active = true;

  IF v_exercicio IS NULL THEN
    RAISE EXCEPTION 'Exercício não encontrado ou programa não está ativo. ID: %', p_exercicio_id;
  END IF;

  v_carga_atual := v_exercicio.carga_kg;
  v_nome_exercicio := v_exercicio.nome_exercicio;
  v_aluno_id := v_exercicio.aluno_id;
  v_whatsapp := v_exercicio.whatsapp;
  v_nova_carga := v_carga_atual + p_variacao_kg;

  RAISE NOTICE '[Propor Carga] Exercício: % | Carga atual: %kg | Variação: %kg | Nova carga: %kg',
    v_nome_exercicio, v_carga_atual, p_variacao_kg, v_nova_carga;

  -- ========================================
  -- CONSTRUIR MENSAGEM
  -- ========================================
  IF p_variacao_kg > 0 THEN
    v_mensagem_texto := format(
      'Notei que você progrediu no exercício *%s*! 💪\n\nDeseja atualizar a carga de %skg para **%skg** no seu plano para os próximos treinos?',
      v_nome_exercicio, v_carga_atual, v_nova_carga
    );
  ELSE
    v_mensagem_texto := format(
      'Notei que você ajustou a carga no exercício *%s*.\n\nDeseja reduzir a carga de %skg para **%skg** no seu plano?',
      v_nome_exercicio, v_carga_atual, v_nova_carga
    );
  END IF;

  -- ========================================
  -- PREPARAR PAYLOADS DOS BOTÕES
  -- ========================================
  v_payload_sim := json_build_object(
    'action', 'confirmar_update_carga',
    'exercicio_id', p_exercicio_id,
    'nova_carga', v_nova_carga
  )::TEXT;

  v_payload_nao := json_build_object(
    'action', 'cancelar_update_carga',
    'exercicio_id', p_exercicio_id
  )::TEXT;

  -- ========================================
  -- BUSCAR API KEY DO BANCO (config_sistema)
  -- ========================================
  SELECT valor INTO v_api_key 
  FROM config_sistema 
  WHERE chave = 'wame_api_key' 
  LIMIT 1;

  IF v_api_key IS NULL THEN
    RAISE NOTICE '[Propor Carga] ⚠️ WAME_API_KEY não encontrada em config_sistema. Retornando dados sem enviar.';
    v_resultado := jsonb_build_object(
      'success', true,
      'message', format('Proposta preparada (API Key não configurada - dados retornados para envio manual)'),
      'detalhes', jsonb_build_object(
        'exercicio_id', p_exercicio_id,
        'nome_exercicio', v_nome_exercicio,
        'carga_atual', v_carga_atual,
        'carga_proposta', v_nova_carga,
        'variacao', p_variacao_kg,
        'aluno_whatsapp', v_whatsapp,
        'mensagem', v_mensagem_texto,
        'payload_sim', v_payload_sim,
        'payload_nao', v_payload_nao
      )
    );
    RETURN v_resultado;
  END IF;

  -- ========================================
  -- FAZER CHAMADA HTTP PARA WAME
  -- ========================================
  v_api_url := 'https://us.api-wa.me/' || v_api_key || '/message/button_reply';

  v_request_body := jsonb_build_object(
    'to', v_whatsapp,
    'header', jsonb_build_object('title', 'Confirmação de Progresso 🚀'),
    'text', v_mensagem_texto,
    'footer', 'Escolha uma opção:',
    'buttons', jsonb_build_array(
      jsonb_build_object(
        'type', 'quick_reply',
        'id', v_payload_sim,
        'text', 'Sim, atualizar!'
      ),
      jsonb_build_object(
        'type', 'quick_reply',
        'id', v_payload_nao,
        'text', 'Não, manter'
      )
    )
  );

  RAISE NOTICE '[Propor Carga] 📤 Enviando requisição HTTP para: %', v_api_url;
  RAISE NOTICE '[Propor Carga] 📱 Destino WhatsApp: %', v_whatsapp;

  -- Disparar requisição HTTP (assíncrona)
  PERFORM net.http_post(
    url := v_api_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := v_request_body,
    timeout_milliseconds := 30000
  );

  RAISE NOTICE '[Propor Carga] ✅ Requisição enviada para WAME!';

  -- ========================================
  -- RETORNAR SUCESSO
  -- ========================================
  v_resultado := jsonb_build_object(
    'success', true,
    'message', format('Proposta de atualização enviada ao aluno para %s', v_nome_exercicio),
    'detalhes', jsonb_build_object(
      'exercicio_id', p_exercicio_id,
      'nome_exercicio', v_nome_exercicio,
      'carga_atual', v_carga_atual,
      'carga_proposta', v_nova_carga,
      'variacao', p_variacao_kg,
      'aluno_whatsapp', v_whatsapp
    )
  );

  RETURN v_resultado;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Erro ao propor atualização de carga: %', SQLERRM;

END;
$$;


ALTER FUNCTION "public"."propor_atualizacao_carga"("p_exercicio_id" "uuid", "p_variacao_kg" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propor_registro_refeicao"("p_aluno_id" "uuid", "p_refeicao" "text", "p_tipo" "text", "p_calorias" numeric, "p_proteinas" numeric, "p_carboidratos" numeric, "p_gorduras" numeric, "p_liquidos_ml" numeric) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_whatsapp VARCHAR;
  v_registro_id UUID;
  v_mensagem_texto TEXT;
  v_payload_sim TEXT;
  v_payload_nao TEXT;
  v_api_key VARCHAR;
  v_api_url TEXT;
  v_request_body JSONB;
  v_horario_atual TEXT;
  v_resultado JSON;
BEGIN
  -- ========================================
  -- LOG DE AUDITORIA
  -- ========================================
  RAISE NOTICE '[PROPOR REFEIÇÃO] Iniciando para aluno: %', p_aluno_id;

  -- ========================================
  -- BUSCAR WHATSAPP DO ALUNO
  -- ========================================
  SELECT whatsapp INTO v_whatsapp
  FROM alunos
  WHERE id = p_aluno_id;

  IF v_whatsapp IS NULL THEN
    RAISE EXCEPTION 'Aluno não encontrado. ID: %', p_aluno_id;
  END IF;

  RAISE NOTICE '[PROPOR REFEIÇÃO] WhatsApp do aluno: %', v_whatsapp;

  -- ========================================
  -- OBTER HORÁRIO ATUAL (TIMEZONE SÃO PAULO)
  -- ========================================
  v_horario_atual := TO_CHAR(NOW() AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI');
  RAISE NOTICE '[PROPOR REFEIÇÃO] Horário: %', v_horario_atual;

  -- ========================================
  -- CRIAR REGISTRO EM BRANCO
  -- ========================================
  RAISE NOTICE '[PROPOR REFEIÇÃO] Criando registro em branco...';

  INSERT INTO daily_consumption_history (
    aluno_id,
    data_registro,
    meta_calorias,
    meta_proteina,
    meta_carboidrato,
    meta_gordura,
    meta_agua_ml,
    consumo_calorias,
    consumo_proteina,
    consumo_carboidrato,
    consumo_gordura,
    consumo_agua_ml,
    aderencia_percentual,
    alimentos_consumidos,
    analise_qualitativa
  )
  VALUES (
    p_aluno_id,
    CURRENT_DATE,
    0, -- metas serão preenchidas na confirmação
    0,
    0,
    0,
    0,
    0, -- consumo zerado (aguardando confirmação)
    0,
    0,
    0,
    0,
    0,
    '[]'::JSONB, -- array vazio
    'AGUARDANDO_CONFIRMACAO' -- flag para identificar
  )
  ON CONFLICT (aluno_id, data_registro) 
  DO NOTHING -- se já existe registro do dia, não faz nada
  RETURNING id INTO v_registro_id;

  -- Se não conseguiu criar (já existe), busca o existente
  IF v_registro_id IS NULL THEN
    SELECT id INTO v_registro_id
    FROM daily_consumption_history
    WHERE aluno_id = p_aluno_id 
      AND data_registro = CURRENT_DATE;
  END IF;

  RAISE NOTICE '[PROPOR REFEIÇÃO] Registro criado/encontrado. ID: %', v_registro_id;

  -- ========================================
  -- CONSTRUIR MENSAGEM
  -- ========================================
  v_mensagem_texto := format(
    E'🍽️ Confirmar Refeição - %s\n\n📋 O QUE VOCÊ COMEU:\n%s\n\n📊 RESUMO NUTRICIONAL:\n• Calorias: %s kcal\n• Proteínas: %sg\n• Carboidratos: %sg\n• Gorduras: %sg\n• Líquidos: %sml\n\nConfirmar este registro?',
    UPPER(p_tipo),
    p_refeicao,
    p_calorias,
    p_proteinas,
    p_carboidratos,
    p_gorduras,
    p_liquidos_ml
  );

  RAISE NOTICE '[PROPOR REFEIÇÃO] Mensagem construída';

  -- ========================================
  -- PREPARAR PAYLOADS DOS BOTÕES
  -- ========================================
  v_payload_sim := json_build_object(
    'action', 'confirmar_registro_refeicao',
    'registro_id', v_registro_id,
    'aluno_id', p_aluno_id,
    'refeicao', p_refeicao,
    'tipo', p_tipo,
    'horario', v_horario_atual,
    'calorias', p_calorias,
    'proteinas', p_proteinas,
    'carboidratos', p_carboidratos,
    'gorduras', p_gorduras,
    'liquidos_ml', p_liquidos_ml
  )::TEXT;

  v_payload_nao := json_build_object(
    'action', 'cancelar_registro_refeicao',
    'registro_id', v_registro_id,
    'aluno_id', p_aluno_id
  )::TEXT;

  -- ========================================
  -- BUSCAR API KEY
  -- ========================================
  SELECT valor INTO v_api_key 
  FROM config_sistema 
  WHERE chave = 'wame_api_key' 
  LIMIT 1;

  IF v_api_key IS NULL THEN
    RAISE NOTICE '[PROPOR REFEIÇÃO] ⚠️ WAME_API_KEY não encontrada. Retornando dados sem enviar.';
    v_resultado := jsonb_build_object(
      'success', true,
      'message', 'Proposta preparada (API Key não configurada)',
      'detalhes', jsonb_build_object(
        'registro_id', v_registro_id,
        'whatsapp', v_whatsapp,
        'mensagem', v_mensagem_texto,
        'payload_sim', v_payload_sim,
        'payload_nao', v_payload_nao
      )
    );
    RETURN v_resultado;
  END IF;

  -- ========================================
  -- ENVIAR BOTÃO WHATSAPP
  -- ========================================
  v_api_url := 'https://us.api-wa.me/' || v_api_key || '/message/button_reply';

  v_request_body := jsonb_build_object(
    'to', v_whatsapp,
    'header', jsonb_build_object('title', '🍽️ Registro de Refeição'),
    'text', v_mensagem_texto,
    'footer', 'Escolha uma opção:',
    'buttons', jsonb_build_array(
      jsonb_build_object(
        'type', 'quick_reply',
        'id', v_payload_sim,
        'text', 'Sim, registrar!'
      ),
      jsonb_build_object(
        'type', 'quick_reply',
        'id', v_payload_nao,
        'text', 'Não, alterar'
      )
    )
  );

  RAISE NOTICE '[PROPOR REFEIÇÃO] 📤 Enviando requisição HTTP para: %', v_api_url;
  RAISE NOTICE '[PROPOR REFEIÇÃO] 📱 Destino WhatsApp: %', v_whatsapp;

  -- Disparar requisição HTTP
  PERFORM net.http_post(
    url := v_api_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := v_request_body,
    timeout_milliseconds := 30000
  );

  RAISE NOTICE '[PROPOR REFEIÇÃO] ✅ Requisição enviada!';

  -- ========================================
  -- RETORNAR SUCESSO
  -- ========================================
  v_resultado := jsonb_build_object(
    'success', true,
    'message', 'Proposta de registro enviada ao aluno',
    'detalhes', jsonb_build_object(
      'registro_id', v_registro_id,
      'tipo_refeicao', p_tipo,
      'calorias', p_calorias,
      'whatsapp', v_whatsapp,
      'horario', v_horario_atual
    )
  );

  RETURN v_resultado;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Erro ao propor registro de refeição: %', SQLERRM;

END;
$$;


ALTER FUNCTION "public"."propor_registro_refeicao"("p_aluno_id" "uuid", "p_refeicao" "text", "p_tipo" "text", "p_calorias" numeric, "p_proteinas" numeric, "p_carboidratos" numeric, "p_gorduras" numeric, "p_liquidos_ml" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rebuild_conquistas_recentes_json"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_achievements_json JSONB;
BEGIN
    RAISE NOTICE 'Executando rebuild_conquistas_recentes_json para o aluno ID: %', p_aluno_id;

    -- 1. Busca as 5 conquistas mais recentes e as agrega em um array JSON.
    SELECT
        jsonb_agg(
            jsonb_build_object(
                'titulo', a.titulo,
                'data', a.data_conquista,
                'categoria', a.categoria
            ) ORDER BY a.data_conquista DESC
        )
    INTO v_achievements_json
    FROM (
        SELECT *
        FROM public.achievements
        WHERE aluno_id = p_aluno_id
        ORDER BY data_conquista DESC
        LIMIT 5 -- Limitamos a 5 para não poluir o prompt
    ) AS a;

    -- 2. Atualiza a coluna JSONB na tabela dynamic_prompts
    UPDATE public.dynamic_prompts
    SET conquistas_recentes_json = COALESCE(v_achievements_json, '[]'::jsonb) -- Garante um array vazio se não houver conquistas
    WHERE aluno_id = p_aluno_id;

    RAISE NOTICE ' -> Coluna conquistas_recentes_json atualizada com sucesso.';
END;
$$;


ALTER FUNCTION "public"."rebuild_conquistas_recentes_json"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rebuild_conquistas_recentes_json"("p_aluno_id" "uuid") IS 'Busca as 5 conquistas mais recentes do aluno e atualiza a coluna `conquistas_recentes_json` em `dynamic_prompts`.';



CREATE OR REPLACE FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_goal_record RECORD;
    v_metric_record RECORD;
    v_progress_kg NUMERIC;
    v_total_kg_target NUMERIC;
    v_progress_percentage NUMERIC;
BEGIN
    RAISE NOTICE 'Executando rebuild_objetivo_ativo_json para o aluno ID: %', p_aluno_id;

    -- 1. Busca a meta ativa do aluno
    SELECT * INTO v_goal_record
    FROM public.goals
    WHERE aluno_id = p_aluno_id AND status = 'ativo'
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE WARNING 'Nenhuma meta ativa encontrada para o aluno ID: %', p_aluno_id;
        -- Limpa o JSON se não houver meta ativa
        UPDATE public.dynamic_prompts SET objetivo_ativo_json = NULL WHERE aluno_id = p_aluno_id;
        RETURN;
    END IF;

    -- 2. Busca a última medição de peso do aluno
    SELECT peso_kg INTO v_metric_record
    FROM public.body_metrics
    WHERE aluno_id = p_aluno_id
    ORDER BY data_medicao DESC
    LIMIT 1;

    -- 3. Calcula as métricas de progresso (se houver dados suficientes)
    v_progress_kg := 0;
    v_progress_percentage := 0;
    IF v_metric_record.peso_kg IS NOT NULL AND v_goal_record.valor_inicial IS NOT NULL AND v_goal_record.target_peso_kg IS NOT NULL THEN
        -- Calcula o total a ser perdido/ganho
        v_total_kg_target := ABS(v_goal_record.valor_inicial - v_goal_record.target_peso_kg);
        -- Calcula o progresso já feito
        v_progress_kg := v_goal_record.valor_inicial - v_metric_record.peso_kg;

        IF v_total_kg_target > 0 THEN
            -- Calcula a porcentagem do progresso
            v_progress_percentage := ROUND((ABS(v_progress_kg) / v_total_kg_target) * 100);
        END IF;
    END IF;

    -- 4. Atualiza a coluna JSONB na tabela dynamic_prompts
    UPDATE public.dynamic_prompts
    SET objetivo_ativo_json = jsonb_build_object(
        'tipo', v_goal_record.type,
        'titulo', v_goal_record.titulo_meta,
        'motivacao', v_goal_record.motivacao_principal,
        'prazo', v_goal_record.data_fim_prevista,
        'progresso', jsonb_build_object(
            'peso_inicial_kg', v_goal_record.valor_inicial,
            'peso_atual_kg', v_metric_record.peso_kg,
            'peso_meta_kg', v_goal_record.target_peso_kg,
            'progresso_kg', ROUND(v_progress_kg, 1),
            'progresso_percentual', v_progress_percentage,
            'dias_decorridos', DATE_PART('day', NOW() - v_goal_record.data_inicio)
        )
    )
    WHERE aluno_id = p_aluno_id;

    RAISE NOTICE ' -> Coluna objetivo_ativo_json atualizada com sucesso.';
END;
$$;


ALTER FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") IS 'Lê a meta ativa e a última medição para calcular o progresso e atualizar a coluna `objetivo_ativo_json` em `dynamic_prompts`.';



CREATE OR REPLACE FUNCTION "public"."rebuild_plano_alimentar_json"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_diet_plan_record RECORD;
    v_prefs_record RECORD;
BEGIN
    RAISE NOTICE 'Executando rebuild_plano_alimentar_json para o aluno ID: %', p_aluno_id;

    -- 1. Busca o plano de dieta ativo
    SELECT * INTO v_diet_plan_record
    FROM public.diet_plans
    WHERE aluno_id = p_aluno_id AND is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE WARNING 'Nenhum plano de dieta ativo encontrado para o aluno ID: %', p_aluno_id;
        UPDATE public.dynamic_prompts SET plano_alimentar_json = NULL WHERE aluno_id = p_aluno_id;
        RETURN;
    END IF;

    -- 2. Busca as preferências alimentares
    SELECT * INTO v_prefs_record
    FROM public.preferencias_alimentares
    WHERE aluno_id = p_aluno_id;

    -- 3. Atualiza a coluna JSONB na tabela dynamic_prompts
    UPDATE public.dynamic_prompts
    SET plano_alimentar_json = jsonb_build_object(
        'versao', v_diet_plan_record.version,
        'metas_diarias', v_diet_plan_record.meta_diaria_geral,
        'plano_do_dia', public.get_diet_for_today(v_diet_plan_record.plano_semanal),
        'preferencias', jsonb_build_object(
            'restricoes', COALESCE(v_prefs_record.restricoes_alimentares, '{}'),
            'nao_gosta', COALESCE(v_prefs_record.alimentos_nao_gosta, '{}'),
            'favoritos', COALESCE(v_prefs_record.alimentos_favoritos, '{}'),
            'disposicao_cozinhar', v_prefs_record.disposicao_cozinhar,
            'orcamento', v_prefs_record.orcamento_alimentar
        )
    )
    WHERE aluno_id = p_aluno_id;

    RAISE NOTICE ' -> Coluna plano_alimentar_json atualizada com sucesso.';
END;
$$;


ALTER FUNCTION "public"."rebuild_plano_alimentar_json"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rebuild_plano_alimentar_json"("p_aluno_id" "uuid") IS 'Combina o plano de dieta ativo com as preferências alimentares para atualizar a coluna `plano_alimentar_json` em `dynamic_prompts`.';



CREATE OR REPLACE FUNCTION "public"."rebuild_plano_treino_json"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_program_record RECORD;
    v_prefs_record RECORD;
BEGIN
    RAISE NOTICE 'Executando rebuild_plano_treino_json (versão completa) para o aluno ID: %', p_aluno_id;

    -- 1. Busca o programa de treino ativo
    SELECT * INTO v_program_record
    FROM public.workout_programs
    WHERE aluno_id = p_aluno_id AND is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE WARNING 'Nenhum programa de treino ativo encontrado para o aluno ID: %', p_aluno_id;
        UPDATE public.dynamic_prompts SET plano_treino_json = NULL WHERE aluno_id = p_aluno_id;
        RETURN;
    END IF;

    -- 2. Busca as preferências de treino
    SELECT * INTO v_prefs_record
    FROM public.preferencias_treino
    WHERE aluno_id = p_aluno_id;

    -- 3. Atualiza a coluna JSONB, agora com o programa semanal completo
    UPDATE public.dynamic_prompts
    SET plano_treino_json = jsonb_build_object(
        'versao', v_program_record.version,
        'nome_programa', v_program_record.nome_programa,
        'objetivo', v_program_record.objetivo,
        'frequencia_semanal', v_program_record.frequencia_semanal,
        'programa_semanal', public.get_full_workout_program_json(v_program_record.id), -- Alteração principal aqui!
        'preferencias', jsonb_build_object(
            'local', v_prefs_record.local_treino,
            'experiencia', v_prefs_record.experiencia_treino,
            'equipamentos', v_prefs_record.equipamentos_disponiveis
        )
    )
    WHERE aluno_id = p_aluno_id;

    RAISE NOTICE ' -> Coluna plano_treino_json atualizada com o programa semanal completo.';
END;
$$;


ALTER FUNCTION "public"."rebuild_plano_treino_json"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rebuild_plano_treino_json"("p_aluno_id" "uuid") IS 'Combina o programa de treino semanal completo com as preferências para atualizar a coluna `plano_treino_json` em `dynamic_prompts`.';



CREATE OR REPLACE FUNCTION "public"."rebuild_prompt_final"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RAISE NOTICE '[Master Trigger] Reconstruindo prompt_final para o aluno ID: %', NEW.aluno_id;

    -- Concatena todas as colunas de contexto para formar o prompt final.
    -- O "E'\n\n'" cria quebras de linha para formatar o texto.
    -- COALESCE garante que, se uma coluna for nula, não cause erro.
    NEW.prompt_final := CONCAT(
        COALESCE(NEW.prompt_base, ''),
        E'\n\n---\n\n# CAMADA 2: CONTEXTO DINÂMICO DO ALUNO\n\n',
        '## SAÚDE E ROTINA:', E'\n', COALESCE(NEW.saude_e_rotina_json::text, '{}'), E'\n\n',
        '## OBJETIVO ATIVO E PROGRESSO:', E'\n', COALESCE(NEW.objetivo_ativo_json::text, '{}'), E'\n\n',
        '## PLANO ALIMENTAR E PREFERÊNCIAS:', E'\n', COALESCE(NEW.plano_alimentar_json::text, '{}'), E'\n\n',
        '## PLANO DE TREINO (PROGRAMA SEMANAL):', E'\n', COALESCE(NEW.plano_treino_json::text, '{}'), E'\n\n',
        '## CONQUISTAS RECENTES:', E'\n', COALESCE(NEW.conquistas_recentes_json::text, '[]'), E'\n\n',
        '## INSTRUÇÕES DO NUTRICIONISTA:', E'\n', COALESCE(NEW.instrucoes_nutricionista_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## INSTRUÇÕES DO PERSONAL TRAINER:', E'\n', COALESCE(NEW.instrucoes_personal_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## CONSIDERAÇÕES FINAIS:', E'\n', COALESCE(NEW.consideracoes_finais_text, 'Seja sempre motivador e baseie-se nos dados para fornecer a melhor orientação possível.')
    );
    
    -- Retorna a linha (NEW) com a coluna `prompt_final` preenchida,
    -- para que a operação (INSERT/UPDATE) seja salva no banco.
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."rebuild_prompt_final"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rebuild_prompt_final"() IS 'Trigger-function acionada ANTES de cada INSERT ou UPDATE na `dynamic_prompts` para concatenar todas as colunas de contexto na coluna `prompt_final`.';



CREATE OR REPLACE FUNCTION "public"."rebuild_saude_e_rotina_json"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_data_record RECORD;
BEGIN
    -- Seleciona a linha de dados de saúde e rotina do aluno
    SELECT * INTO v_data_record
    FROM public.saude_e_rotina
    WHERE aluno_id = p_aluno_id;

    IF NOT FOUND THEN
        -- Se não houver dados, não faz nada.
        RETURN;
    END IF;

    -- Atualiza a coluna JSONB correspondente na tabela dynamic_prompts
    UPDATE public.dynamic_prompts
    SET saude_e_rotina_json = jsonb_build_object(
        'condicoes_medicas', COALESCE(v_data_record.condicoes_medicas, '{}'),
        'medicamentos', COALESCE(v_data_record.medicacoes_em_uso, '[]'::jsonb),
        'alergias', COALESCE(v_data_record.alergias, '{}'),
        'lesoes_limitacoes', COALESCE(v_data_record.lesoes_limitacoes, '[]'::jsonb),
        'profissao', v_data_record.profissao,
        'horario_acordar', TO_CHAR(v_data_record.horario_acordar, 'HH24:MI'),
        'horario_dormir', TO_CHAR(v_data_record.horario_dormir, 'HH24:MI'),
        'altura_cm', v_data_record.altura_cm,
        'sexo', v_data_record.sexo,
        'idade', DATE_PART('year', AGE(v_data_record.data_nascimento))
    )
    WHERE aluno_id = p_aluno_id;
END;
$$;


ALTER FUNCTION "public"."rebuild_saude_e_rotina_json"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rebuild_saude_e_rotina_json"("p_aluno_id" "uuid") IS 'Lê os dados da tabela `saude_e_rotina` e atualiza a coluna de cache `saude_e_rotina_json` na tabela `dynamic_prompts`.';



CREATE OR REPLACE FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name run_aggregation_and_reset_flag
 * @description Esta é a função que o pg_cron chama. Ela executa a agregação
 * para um aluno específico e depois reseta a flag de agendamento.
 */
BEGIN
    -- Executa a agregação (a função principal)
    PERFORM public.agregar_mensagens_para_aluno(p_aluno_id);

    -- Reseta a flag para permitir futuros agendamentos
    UPDATE public.alunos
    SET agregacao_agendada = false
    WHERE id = p_aluno_id;
    
    RAISE NOTICE '[Cron Runner] Agregação executada para o aluno % e flag resetada.', p_aluno_id;
END;
$$;


ALTER FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."schedule_aggregation_on_new_message"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name schedule_aggregation_on_new_message
 * @description Acionada após a inserção de uma nova mensagem, esta
 * função implementa a lógica de agendamento "sob demanda".
 * @changelog v1.1: Corrigida a sintaxe de construção do comando para o pg_cron.
 */
DECLARE
    v_agendado BOOLEAN;
    v_command TEXT; -- Variável para armazenar o comando a ser executado
BEGIN
    -- Verifica o status do agendamento para o aluno da nova mensagem
    SELECT agregacao_agendada INTO v_agendado
    FROM public.alunos
    WHERE id = NEW.aluno_id;

    -- Se não houver agendamento ativo, cria um
    IF v_agendado = false THEN
        RAISE NOTICE '[Trigger Agendador] Nenhuma agregação pendente para o aluno %. Agendando para daqui a 10 segundos...', NEW.aluno_id;

        -- <<-- INÍCIO DA CORREÇÃO -->>
        -- Constrói o comando a ser executado de forma segura usando format()
        -- %L é um especificador que trata o valor como um literal SQL, evitando injeção de SQL.
        v_command := format('SELECT public.run_aggregation_and_reset_flag(%L)', NEW.aluno_id);
        
        -- Agenda a execução da função principal usando o comando formatado
        PERFORM cron.schedule(
            'aggregate-' || NEW.aluno_id::text, -- Nome do job único
            '10 seconds', -- Atraso para a execução
            v_command -- A variável com o comando correto
        );
        -- <<-- FIM DA CORREÇÃO -->>

        -- Marca o aluno como "agendamento pendente" para evitar duplicatas
        UPDATE public.alunos
        SET agregacao_agendada = true
        WHERE id = NEW.aluno_id;
    ELSE
        RAISE NOTICE '[Trigger Agendador] Agregação já pendente para o aluno %. Nenhuma ação necessária.', NEW.aluno_id;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."schedule_aggregation_on_new_message"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."testar_edge_propor_refeicao"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_supabase_url TEXT;
  v_service_key TEXT;
  v_request_id BIGINT;
  v_response TEXT;
BEGIN
  -- Buscar credenciais
  SELECT valor INTO v_supabase_url FROM config_sistema WHERE chave = 'supabase_url';
  SELECT valor INTO v_service_key FROM config_sistema WHERE chave = 'service_role_key';
  
  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RETURN 'ERRO: Credenciais não configuradas';
  END IF;
  
  RAISE NOTICE '[Teste Edge] Chamando Edge Function propor-registro-refeicao...';
  
  -- Chamar Edge Function com dados de teste
  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/propor-registro-refeicao',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body := jsonb_build_object(
      'aluno_id', 'b4ba21f1-e759-4e7c-9291-f02a6a74c42e',
      'refeicao', 'Jantar: 200g frango cozido, 300g abóbora, 50g beterraba, 1 colher azeite',
      'tipo', 'Jantar',
      'calorias', 650,
      'proteinas', 66,
      'carboidratos', 47.5,
      'gorduras', 21,
      'liquidos_ml', 200
    ),
    timeout_milliseconds := 30000
  ) INTO v_request_id;
  
  RAISE NOTICE '[Teste Edge] Request ID: %', v_request_id;
  
  -- Aguardar resposta
  PERFORM pg_sleep(3);
  
  -- Buscar resultado
  SELECT content::TEXT INTO v_response
  FROM net._http_response
  WHERE id = v_request_id;
  
  RAISE NOTICE '[Teste Edge] Resposta: %', v_response;
  
  RETURN v_response;
  
EXCEPTION WHEN OTHERS THEN
  RETURN 'ERRO: ' || SQLERRM;
END;
$$;


ALTER FUNCTION "public"."testar_edge_propor_refeicao"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."testar_envio_whatsapp"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_api_key TEXT;
  v_request_id BIGINT;
BEGIN
  SELECT valor INTO v_api_key FROM config_sistema WHERE chave = 'wame_api_key';
  
  SELECT net.http_post(
    url := 'https://us.api-wa.me/' || v_api_key || '/message/text',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object(
      'to', '554892086968',
      'text', 'Teste de mensagem do Supabase'
    )
  ) INTO v_request_id;
  
  RETURN 'Request ID: ' || v_request_id;
END;
$$;


ALTER FUNCTION "public"."testar_envio_whatsapp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."testar_extrator_texto"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_request_id BIGINT;
    v_texto TEXT;
BEGIN
    -- Texto exemplo
    v_texto := 'Café da manhã: Aveia (30g), Banana (100g), Frango (100g), Mamão (170g). Almoço: Abóbora (330g), Batata (100g), Frango (250g), Azeite (7g). Jantar: Beterraba (300g), Abóbora (50g), Frango (200g).';
    
    -- Chama a Edge Function
    SELECT INTO v_request_id net.http_post(
        url := 'https://hiufaonhsxlnoozwbygq.supabase.co/functions/v1/extrair-macros-de-texto',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || (SELECT valor FROM config_sistema WHERE chave = 'service_role_key')
        ),
        body := jsonb_build_object('texto_alimentos', v_texto),
        timeout_milliseconds := 30000
    );
    
    RETURN 'Request enviado! ID: ' || v_request_id;
END;
$$;


ALTER FUNCTION "public"."testar_extrator_texto"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."testar_proposta_carga"("p_aluno_id" "uuid", "p_nome_exercicio" "text", "p_variacao_kg" numeric) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name testar_proposta_carga
 * @version 2.2.0
 * @changelog v2.2: Alterado para usar a tabela `net._http_response`
 * em vez de `net.http_collect_response`, que é o padrão
 * mais robusto neste ambiente.
 */
DECLARE
    v_exercicio_id UUID;
    v_supabase_url TEXT;
    v_service_key TEXT;
    v_request_id BIGINT;
    v_response TEXT;
BEGIN
    -- Busca o ID do exercício (lógica inalterada)
    RAISE NOTICE '[Teste de Carga] Buscando exercício "%" para o aluno ID: %...', p_nome_exercicio, p_aluno_id;
    SELECT we.id INTO v_exercicio_id
    FROM public.workout_exercises AS we
    JOIN public.program_workouts AS pw ON we.workout_id = pw.id
    JOIN public.workout_programs AS wp ON pw.program_id = wp.id
    WHERE wp.aluno_id = p_aluno_id
      AND we.nome_exercicio ILIKE '%' || p_nome_exercicio || '%'
      AND wp.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Nenhum exercício encontrado com o nome "%" para o aluno ativo especificado.', p_nome_exercicio;
    END IF;
    RAISE NOTICE ' -> Exercício encontrado com ID: %', v_exercicio_id;

    -- Busca credenciais (lógica inalterada)
    SELECT valor INTO v_supabase_url FROM public.config_sistema WHERE chave = 'supabase_url';
    SELECT valor INTO v_service_key FROM public.config_sistema WHERE chave = 'service_role_key';
    IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
        RAISE EXCEPTION 'Credenciais não configuradas em config_sistema.';
    END IF;

    -- <<-- INÍCIO DA CORREÇÃO -->>

    -- Etapa 1: Dispara a requisição para a Edge Function e obtém o ID
    SELECT net.http_post(
        url := v_supabase_url || '/functions/v1/propor-atualizacao-carga',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_service_key),
        body := jsonb_build_object('exercicio_id', v_exercicio_id, 'variacao_kg', p_variacao_kg),
        timeout_milliseconds := 30000
    ) INTO v_request_id;

    -- Etapa 2: Aguarda um momento para a resposta chegar.
    PERFORM pg_sleep(3); -- Espera de 3 segundos

    -- Etapa 3: Busca o resultado diretamente na tabela de respostas.
    SELECT content::TEXT INTO v_response
    FROM net._http_response
    WHERE id = v_request_id;
    
    -- <<-- FIM DA CORREÇÃO -->>

    RAISE NOTICE '[Teste de Carga] ✅ Teste concluído. Resposta da função: %', v_response;
    RETURN v_response;
END;
$$;


ALTER FUNCTION "public"."testar_proposta_carga"("p_aluno_id" "uuid", "p_nome_exercicio" "text", "p_variacao_kg" numeric) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."achievements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "goal_id" "uuid",
    "data_conquista" "date" DEFAULT CURRENT_DATE NOT NULL,
    "titulo" "text" NOT NULL,
    "descricao" "text",
    "categoria" character varying(30) NOT NULL,
    "metadata" "jsonb"
);


ALTER TABLE "public"."achievements" OWNER TO "postgres";


COMMENT ON TABLE "public"."achievements" IS 'Registra marcos e conquistas do aluno (ex: perdeu 2kg, treinou 7 dias seguidos). Populada automaticamente pelo sistema para fins de gamificação e motivação.';



COMMENT ON COLUMN "public"."achievements"."goal_id" IS 'Opcional. Vincula a conquista a uma meta específica.';



COMMENT ON COLUMN "public"."achievements"."titulo" IS 'O título da conquista (ex: "Semana Perfeita!").';



COMMENT ON COLUMN "public"."achievements"."descricao" IS 'Descrição detalhada da conquista (ex: "Você completou 100% dos treinos planejados na última semana.").';



COMMENT ON COLUMN "public"."achievements"."categoria" IS 'Categoria da conquista (ex: PESO, TREINO, DIETA, MEDIDAS).';



CREATE TABLE IF NOT EXISTS "public"."alunos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome_completo" character varying(255) NOT NULL,
    "whatsapp" character varying(20) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "subscription_status" character varying(30) DEFAULT 'trial'::character varying,
    "last_interaction_at" timestamp with time zone,
    "agregacao_agendada" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."alunos" OWNER TO "postgres";


COMMENT ON TABLE "public"."alunos" IS 'Tabela central de usuários/alunos da plataforma NutriCoach AI';



COMMENT ON COLUMN "public"."alunos"."subscription_status" IS 'Status atual da assinatura do aluno (ex: trial, active, cancelled).';



COMMENT ON COLUMN "public"."alunos"."last_interaction_at" IS 'Timestamp da última mensagem recebida do aluno, para controle de atividade.';



COMMENT ON COLUMN "public"."alunos"."agregacao_agendada" IS 'Flag booleana que indica se já existe um job de agregação de mensagens agendado para este aluno. Controlado por trigger.';



CREATE TABLE IF NOT EXISTS "public"."body_metrics" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "data_medicao" "date" DEFAULT CURRENT_DATE NOT NULL,
    "peso_kg" numeric(5,2) NOT NULL,
    "altura_cm" numeric(5,2) NOT NULL,
    "circunferencia_pescoco_cm" numeric(5,2),
    "circunferencia_cintura_cm" numeric(5,2),
    "circunferencia_quadril_cm" numeric(5,2),
    "percentual_gordura" numeric(4,2),
    "fotos_urls" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notas" "text",
    "feedback_subjetivo" "jsonb",
    "circunferencia_peito_cm" numeric(5,2),
    "medidas_json" "jsonb",
    CONSTRAINT "body_metrics_altura_cm_check" CHECK ((("altura_cm" > (0)::numeric) AND ("altura_cm" < (300)::numeric))),
    CONSTRAINT "body_metrics_circunferencia_cintura_cm_check" CHECK ((("circunferencia_cintura_cm" > (0)::numeric) AND ("circunferencia_cintura_cm" < (200)::numeric))),
    CONSTRAINT "body_metrics_circunferencia_pescoco_cm_check" CHECK ((("circunferencia_pescoco_cm" > (0)::numeric) AND ("circunferencia_pescoco_cm" < (100)::numeric))),
    CONSTRAINT "body_metrics_circunferencia_quadril_cm_check" CHECK ((("circunferencia_quadril_cm" > (0)::numeric) AND ("circunferencia_quadril_cm" < (200)::numeric))),
    CONSTRAINT "body_metrics_percentual_gordura_check" CHECK ((("percentual_gordura" >= (3)::numeric) AND ("percentual_gordura" <= (60)::numeric))),
    CONSTRAINT "body_metrics_peso_kg_check" CHECK ((("peso_kg" > (0)::numeric) AND ("peso_kg" < (300)::numeric)))
);


ALTER TABLE "public"."body_metrics" OWNER TO "postgres";


COMMENT ON TABLE "public"."body_metrics" IS 'Histórico de medições corporais e biométricas dos alunos';



COMMENT ON COLUMN "public"."body_metrics"."feedback_subjetivo" IS 'JSON para armazenar o feedback subjetivo do aluno no dia da medição (ex: {"qualidade_sono": 8, "nivel_energia": 7, "sentimento_geral": "Mais disposto"}).';



COMMENT ON COLUMN "public"."body_metrics"."circunferencia_peito_cm" IS 'Medida da circunferência do peitoral em centímetros.';



COMMENT ON COLUMN "public"."body_metrics"."medidas_json" IS 'JSON para armazenar medidas corporais secundárias (ex: braços, coxas, panturrilhas).';



CREATE TABLE IF NOT EXISTS "public"."completions_old" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "history" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processado" boolean DEFAULT false,
    "timestamp_processamento" timestamp with time zone,
    "erro_processamento" "text"
);


ALTER TABLE "public"."completions_old" OWNER TO "postgres";


COMMENT ON TABLE "public"."completions_old" IS 'Tabela depreciada em 13/10/2025. O gerenciamento de histórico de conversa agora é feito pela OpenAI (Responses API). Substituída pela `chat_history` para logging simples.';



COMMENT ON COLUMN "public"."completions_old"."processado" IS 'Flag se já foi processado pela LLM.';



COMMENT ON COLUMN "public"."completions_old"."timestamp_processamento" IS 'Timestamp de quando foi processado.';



COMMENT ON COLUMN "public"."completions_old"."erro_processamento" IS 'Mensagem de erro se falhou.';



CREATE TABLE IF NOT EXISTS "public"."config_sistema" (
    "chave" "text" NOT NULL,
    "valor" "text" NOT NULL,
    "descricao" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."config_sistema" OWNER TO "postgres";


COMMENT ON TABLE "public"."config_sistema" IS 'Configurações sensíveis do sistema NutriCoach.
Esta tabela armazena credenciais e URLs necessárias para chamadas HTTP internas.

VARIÁVEIS DISPONÍVEIS:
- supabase_url: URL base do projeto Supabase
- service_role_key: Chave de autenticação service_role

SEGURANÇA:
- Protegida por RLS (Row Level Security)
- Apenas service_role pode ler
- Usada por funções RPC para chamadas HTTP internas

COMO USAR NAS FUNÇÕES:
SELECT valor INTO v_url FROM config_sistema WHERE chave = ''supabase_url'';
SELECT valor INTO v_key FROM config_sistema WHERE chave = ''service_role_key'';';



CREATE TABLE IF NOT EXISTS "public"."daily_consumption_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "data_registro" "date" NOT NULL,
    "meta_calorias" integer DEFAULT 0,
    "meta_proteina" integer DEFAULT 0,
    "meta_carboidrato" integer DEFAULT 0,
    "meta_gordura" integer DEFAULT 0,
    "meta_agua_ml" integer DEFAULT 0,
    "consumo_calorias" integer DEFAULT 0 NOT NULL,
    "consumo_proteina" integer DEFAULT 0 NOT NULL,
    "consumo_carboidrato" integer DEFAULT 0 NOT NULL,
    "consumo_gordura" integer DEFAULT 0 NOT NULL,
    "consumo_agua_ml" integer DEFAULT 0 NOT NULL,
    "aderencia_percentual" numeric(5,2) DEFAULT 0,
    "alimentos_consumidos" "jsonb" DEFAULT '[]'::"jsonb",
    "analise_qualitativa" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confirmada" boolean DEFAULT false,
    CONSTRAINT "daily_consumption_history_aderencia_percentual_check" CHECK ((("aderencia_percentual" >= (0)::numeric) AND ("aderencia_percentual" <= (100)::numeric)))
);


ALTER TABLE "public"."daily_consumption_history" OWNER TO "postgres";


COMMENT ON TABLE "public"."daily_consumption_history" IS 'Histórico consolidado de consumo alimentar diário';



CREATE TABLE IF NOT EXISTS "public"."daily_workout_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "data_treino" "date" NOT NULL,
    "treino_realizado" "jsonb" NOT NULL,
    "volume_total_kg" integer NOT NULL,
    "duracao_minutos" integer,
    "aderencia_percentual" numeric(5,2) NOT NULL,
    "progressoes" "jsonb" DEFAULT '[]'::"jsonb",
    "regressoes" "jsonb" DEFAULT '[]'::"jsonb",
    "mantidos" "jsonb" DEFAULT '[]'::"jsonb",
    "analise_qualitativa" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_workout_logs_aderencia_percentual_check" CHECK ((("aderencia_percentual" >= (0)::numeric) AND ("aderencia_percentual" <= (100)::numeric)))
);


ALTER TABLE "public"."daily_workout_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."daily_workout_logs" IS 'Histórico consolidado de treinos realizados diariamente';



CREATE TABLE IF NOT EXISTS "public"."diet_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "meta_diaria_geral" "jsonb" NOT NULL,
    "plano_semanal" "jsonb" NOT NULL,
    "substituicoes" "jsonb" DEFAULT '{}'::"jsonb",
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_fim" "date",
    "notas" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."diet_plans" OWNER TO "postgres";


COMMENT ON TABLE "public"."diet_plans" IS 'Planos alimentares personalizados e versionados para cada aluno';



CREATE TABLE IF NOT EXISTS "public"."dynamic_prompts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "prompt_base" "text",
    "saude_e_rotina_json" "jsonb",
    "objetivo_ativo_json" "jsonb",
    "plano_alimentar_json" "jsonb",
    "plano_treino_json" "jsonb",
    "conquistas_recentes_json" "jsonb",
    "instrucoes_nutricionista_text" "text",
    "instrucoes_personal_text" "text",
    "consideracoes_finais_text" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "prompt_final" "text",
    "last_response_id" "text"
);


ALTER TABLE "public"."dynamic_prompts" OWNER TO "postgres";


COMMENT ON TABLE "public"."dynamic_prompts" IS 'Tabela central de cache de contexto para a IA. Cada coluna armazena um "bloco" de informações do aluno, que são atualizadas por triggers para montagem eficiente do prompt.';



COMMENT ON COLUMN "public"."dynamic_prompts"."prompt_base" IS 'O template estático do prompt (personalidade e regras do Dr. NutriCoach).';



COMMENT ON COLUMN "public"."dynamic_prompts"."saude_e_rotina_json" IS 'Cache dos dados da tabela `saude_e_rotina`.';



COMMENT ON COLUMN "public"."dynamic_prompts"."objetivo_ativo_json" IS 'Cache do progresso da meta ativa, calculado a partir de `goals` e `body_metrics`.';



COMMENT ON COLUMN "public"."dynamic_prompts"."plano_alimentar_json" IS 'Cache do plano de dieta ativo (`diet_plans`) enriquecido com as preferências (`preferencias_alimentares`).';



COMMENT ON COLUMN "public"."dynamic_prompts"."plano_treino_json" IS 'Cache do programa de treino ativo (tabelas de `workout`) enriquecido com as preferências (`preferencias_treino`).';



COMMENT ON COLUMN "public"."dynamic_prompts"."conquistas_recentes_json" IS 'Cache das últimas conquistas da tabela `achievements`.';



COMMENT ON COLUMN "public"."dynamic_prompts"."instrucoes_nutricionista_text" IS 'Instruções personalizadas do nutricionista para o aluno.';



COMMENT ON COLUMN "public"."dynamic_prompts"."instrucoes_personal_text" IS 'Instruções personalizadas do personal trainer para o aluno.';



COMMENT ON COLUMN "public"."dynamic_prompts"."consideracoes_finais_text" IS 'Texto final de encerramento do prompt com diretrizes gerais.';



COMMENT ON COLUMN "public"."dynamic_prompts"."prompt_final" IS 'O conteúdo completo e final do prompt, concatenado automaticamente por um trigger, pronto para ser enviado à IA.';



CREATE TABLE IF NOT EXISTS "public"."dynamic_prompts_old" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "data_validade" "date" NOT NULL,
    "prompt_text" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."dynamic_prompts_old" OWNER TO "postgres";


COMMENT ON TABLE "public"."dynamic_prompts_old" IS 'Tabela depreciada em 13/10/2025. Substituída pela nova tabela `dynamic_prompts` com colunas JSONB modulares. Será removida em breve.';



CREATE TABLE IF NOT EXISTS "public"."goals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "type" character varying(30) NOT NULL,
    "target_peso_kg" numeric(5,2),
    "target_percentual_gordura" numeric(4,2),
    "prazo_semanas" integer,
    "motivacao_principal" "text",
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_fim" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "titulo_meta" character varying(255),
    "data_fim_prevista" "date",
    "status" character varying(30) DEFAULT 'ativo'::character varying NOT NULL,
    "valor_inicial" numeric,
    "motivo_cancelamento" "text",
    CONSTRAINT "goals_prazo_semanas_check" CHECK ((("prazo_semanas" > 0) AND ("prazo_semanas" <= 104))),
    CONSTRAINT "goals_target_percentual_gordura_check" CHECK ((("target_percentual_gordura" >= (3)::numeric) AND ("target_percentual_gordura" <= (60)::numeric))),
    CONSTRAINT "goals_target_peso_kg_check" CHECK ((("target_peso_kg" > (0)::numeric) AND ("target_peso_kg" < (300)::numeric))),
    CONSTRAINT "goals_type_check" CHECK ((("type")::"text" = ANY ((ARRAY['weight_loss'::character varying, 'muscle_gain'::character varying, 'recomposition'::character varying, 'maintenance'::character varying])::"text"[])))
);


ALTER TABLE "public"."goals" OWNER TO "postgres";


COMMENT ON TABLE "public"."goals" IS 'Objetivos de fitness e nutrição definidos pelos alunos';



COMMENT ON COLUMN "public"."goals"."titulo_meta" IS 'Um nome ou título para a meta (ex: "Projeto Verão -10kg").';



COMMENT ON COLUMN "public"."goals"."data_fim_prevista" IS 'A data limite que o aluno estipulou para alcançar a meta.';



COMMENT ON COLUMN "public"."goals"."status" IS 'O estado atual da meta (ex: ativo, concluido_sucesso, abandonado).';



COMMENT ON COLUMN "public"."goals"."valor_inicial" IS 'O valor da métrica principal (ex: peso) no momento da criação da meta, para cálculo de progresso.';



COMMENT ON COLUMN "public"."goals"."motivo_cancelamento" IS 'Justificativa para uma meta ter sido interrompida ou cancelada.';



CREATE TABLE IF NOT EXISTS "public"."historico_atualizacoes_exercicio" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "exercicio_id" "uuid" NOT NULL,
    "carga_anterior" numeric NOT NULL,
    "carga_nova" numeric NOT NULL,
    "tipo_mudanca" character varying(100),
    "timestamp" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."historico_atualizacoes_exercicio" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."instrucoes_nutricionista" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "instrucoes_texto" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."instrucoes_nutricionista" OWNER TO "postgres";


COMMENT ON TABLE "public"."instrucoes_nutricionista" IS 'Armazena instruções específicas e personalizadas de um nutricionista para o aluno.';



CREATE TABLE IF NOT EXISTS "public"."instrucoes_personal" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "instrucoes_texto" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."instrucoes_personal" OWNER TO "postgres";


COMMENT ON TABLE "public"."instrucoes_personal" IS 'Armazena instruções específicas e personalizadas de um personal trainer para o aluno.';



CREATE TABLE IF NOT EXISTS "public"."logs_funcoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome_funcao" character varying(255) NOT NULL,
    "parametros" "jsonb",
    "timestamp" timestamp with time zone DEFAULT "now"(),
    "status" character varying(50)
);


ALTER TABLE "public"."logs_funcoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mensagens_temporarias" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid",
    "whatsapp" character varying(20) NOT NULL,
    "chat_id" character varying(100) NOT NULL,
    "mensagem" "text" NOT NULL,
    "tipo" character varying(20) NOT NULL,
    "tem_audio" boolean DEFAULT false,
    "timestamp_mensagem" timestamp with time zone NOT NULL,
    "timestamp_recebimento" timestamp with time zone DEFAULT "now"() NOT NULL,
    "agregado" boolean DEFAULT false,
    "completion_id" "uuid",
    "timestamp_agregacao" timestamp with time zone,
    "instance_id" character varying(100),
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "resposta" "text",
    "tipo_mensagem" character varying(30) DEFAULT 'RECEBIDA'::character varying NOT NULL,
    "audio_base64" "text"
);


ALTER TABLE "public"."mensagens_temporarias" OWNER TO "postgres";


COMMENT ON TABLE "public"."mensagens_temporarias" IS 'Tabela transitória para mensagens do webhook. Retenção: 24h após agregação.';



COMMENT ON COLUMN "public"."mensagens_temporarias"."aluno_id" IS 'FK para alunos. NULL se não encontrado.';



COMMENT ON COLUMN "public"."mensagens_temporarias"."whatsapp" IS 'Número WhatsApp extraído (apenas dígitos).';



COMMENT ON COLUMN "public"."mensagens_temporarias"."mensagem" IS 'Conteúdo textual. Para áudios, contém fallback.';



COMMENT ON COLUMN "public"."mensagens_temporarias"."agregado" IS 'Flag de controle. false=aguardando, true=processado.';



COMMENT ON COLUMN "public"."mensagens_temporarias"."completion_id" IS 'FK para completions. Preenchido após agregação.';



COMMENT ON COLUMN "public"."mensagens_temporarias"."resposta" IS 'Armazena a resposta da LLM correspondente à mensagem agregada. Preenchido apenas em linhas com tipo_mensagem = ''AGREGADA_SISTEMA''.';



COMMENT ON COLUMN "public"."mensagens_temporarias"."tipo_mensagem" IS 'Identifica a origem da mensagem (RECEBIDA, AGREGADA_SISTEMA). Essencial para o novo fluxo de agregação.';



COMMENT ON COLUMN "public"."mensagens_temporarias"."audio_base64" IS 'Armazena o conteúdo do arquivo de áudio codificado em Base64, pronto para ser enviado para a API de transcrição.';



CREATE TABLE IF NOT EXISTS "public"."payment_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "subscription_id" "uuid" NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "tipo" character varying(20) NOT NULL,
    "status" character varying(20) NOT NULL,
    "valor_centavos" integer NOT NULL,
    "external_transaction_id" character varying(255),
    "payment_gateway" character varying(50) NOT NULL,
    "payment_method" character varying(50),
    "error_code" character varying(100),
    "error_message" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "data_processamento" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payment_transactions_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'processing'::character varying, 'succeeded'::character varying, 'failed'::character varying])::"text"[]))),
    CONSTRAINT "payment_transactions_tipo_check" CHECK ((("tipo")::"text" = ANY ((ARRAY['payment'::character varying, 'refund'::character varying, 'chargeback'::character varying])::"text"[]))),
    CONSTRAINT "payment_transactions_valor_centavos_check" CHECK (("valor_centavos" > 0))
);


ALTER TABLE "public"."payment_transactions" OWNER TO "postgres";


COMMENT ON TABLE "public"."payment_transactions" IS 'Histórico completo de transações de pagamento';



CREATE TABLE IF NOT EXISTS "public"."preferences_old" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "restricoes_alimentares" "text"[] DEFAULT ARRAY[]::"text"[],
    "disliked_foods" "text"[] DEFAULT ARRAY[]::"text"[],
    "favorite_foods" "text"[] DEFAULT ARRAY[]::"text"[],
    "alergias_intolerancia" "text"[] DEFAULT ARRAY[]::"text"[],
    "disposicao_cozinhar" character varying(20) DEFAULT 'medium'::character varying,
    "orcamento_alimentar_mensal" numeric(10,2),
    "numero_refeicoes_dia" integer DEFAULT 4,
    "local_treino" character varying(20) DEFAULT 'gym'::character varying NOT NULL,
    "equipamentos_disponiveis" "text"[] DEFAULT ARRAY[]::"text"[],
    "frequencia_semanal_treino" integer DEFAULT 4,
    "tempo_sessao_minutos" integer DEFAULT 60,
    "disliked_exercises" "text"[] DEFAULT ARRAY[]::"text"[],
    "injuries_limitations" "jsonb" DEFAULT '[]'::"jsonb",
    "horario_acordar" time without time zone,
    "horario_dormir" time without time zone,
    "horarios_treino_preferidos" "text"[] DEFAULT ARRAY[]::"text"[],
    "dias_medicao" "text"[] DEFAULT ARRAY[]::"text"[],
    "horario_relatorios" time without time zone DEFAULT '20:00:00'::time without time zone,
    "frequencia_notificacoes" character varying(20) DEFAULT 'medium'::character varying,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "preferences_disposicao_cozinhar_check" CHECK ((("disposicao_cozinhar")::"text" = ANY ((ARRAY['low'::character varying, 'medium'::character varying, 'high'::character varying])::"text"[]))),
    CONSTRAINT "preferences_frequencia_notificacoes_check" CHECK ((("frequencia_notificacoes")::"text" = ANY ((ARRAY['low'::character varying, 'medium'::character varying, 'high'::character varying])::"text"[]))),
    CONSTRAINT "preferences_frequencia_semanal_treino_check" CHECK ((("frequencia_semanal_treino" >= 3) AND ("frequencia_semanal_treino" <= 6))),
    CONSTRAINT "preferences_local_treino_check" CHECK ((("local_treino")::"text" = ANY ((ARRAY['gym'::character varying, 'home'::character varying, 'both'::character varying])::"text"[]))),
    CONSTRAINT "preferences_numero_refeicoes_dia_check" CHECK ((("numero_refeicoes_dia" >= 3) AND ("numero_refeicoes_dia" <= 6))),
    CONSTRAINT "preferences_tempo_sessao_minutos_check" CHECK ((("tempo_sessao_minutos" >= 30) AND ("tempo_sessao_minutos" <= 120)))
);


ALTER TABLE "public"."preferences_old" OWNER TO "postgres";


COMMENT ON TABLE "public"."preferences_old" IS 'Tabela depreciada em 13/10/2025. Os dados foram migrados para `preferencias_alimentares` e `preferencias_treino`. Esta tabela será removida em uma futura migração.';



CREATE TABLE IF NOT EXISTS "public"."preferencias_alimentares" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "restricoes_alimentares" "text"[],
    "alimentos_nao_gosta" "text"[],
    "alimentos_favoritos" "text"[],
    "disposicao_cozinhar" character varying(20),
    "orcamento_alimentar" character varying(30),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."preferencias_alimentares" OWNER TO "postgres";


COMMENT ON TABLE "public"."preferencias_alimentares" IS 'Armazena todas as preferências do aluno relacionadas à alimentação. Substitui parte da antiga tabela `preferences`.';



COMMENT ON COLUMN "public"."preferencias_alimentares"."restricoes_alimentares" IS 'Array com restrições de dieta (ex: {"vegetariano", "sem glúten"}).';



COMMENT ON COLUMN "public"."preferencias_alimentares"."alimentos_nao_gosta" IS 'Array com alimentos que o aluno explicitamente não gosta.';



COMMENT ON COLUMN "public"."preferencias_alimentares"."alimentos_favoritos" IS 'Array com alimentos que o aluno gosta e gostaria de incluir no plano.';



COMMENT ON COLUMN "public"."preferencias_alimentares"."disposicao_cozinhar" IS 'Nível de disposição para preparar as próprias refeições (ex: baixa, média, alta).';



COMMENT ON COLUMN "public"."preferencias_alimentares"."orcamento_alimentar" IS 'Orçamento para alimentação (ex: econômico, moderado, flexível).';



CREATE TABLE IF NOT EXISTS "public"."preferencias_treino" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "local_treino" character varying(30),
    "equipamentos_disponiveis" "text"[],
    "experiencia_treino" character varying(30),
    "dias_preferenciais_treino" "text"[],
    "horarios_preferenciais_treino" "text"[],
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."preferencias_treino" OWNER TO "postgres";


COMMENT ON TABLE "public"."preferencias_treino" IS 'Armazena todas as preferências do aluno relacionadas ao treino. Substitui parte da antiga tabela `preferences`.';



COMMENT ON COLUMN "public"."preferencias_treino"."local_treino" IS 'Onde o aluno treina (ex: academia, casa, parque).';



COMMENT ON COLUMN "public"."preferencias_treino"."equipamentos_disponiveis" IS 'Array com os equipamentos que o aluno tem acesso.';



COMMENT ON COLUMN "public"."preferencias_treino"."experiencia_treino" IS 'Nível de experiência do aluno (ex: iniciante, intermediário, avançado).';



COMMENT ON COLUMN "public"."preferencias_treino"."dias_preferenciais_treino" IS 'Dias da semana que o aluno prefere treinar.';



COMMENT ON COLUMN "public"."preferencias_treino"."horarios_preferenciais_treino" IS 'Períodos do dia que o aluno prefere treinar (ex: {"manhã", "noite"}).';



CREATE TABLE IF NOT EXISTS "public"."processed_webhook_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message_id" "text" NOT NULL,
    "event_type" "text" NOT NULL,
    "aluno_id" "uuid",
    "processed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb"
);


ALTER TABLE "public"."processed_webhook_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."program_workouts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "program_id" "uuid" NOT NULL,
    "dia_da_semana" smallint NOT NULL,
    "nome_treino" character varying(255)
);


ALTER TABLE "public"."program_workouts" OWNER TO "postgres";


COMMENT ON TABLE "public"."program_workouts" IS 'Tabela de ligação que define qual treino ocorre em qual dia da semana para um determinado programa.';



CREATE TABLE IF NOT EXISTS "public"."saude_e_rotina" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "condicoes_medicas" "text"[],
    "medicacoes_em_uso" "jsonb",
    "alergias" "text"[],
    "lesoes_limitacoes" "jsonb",
    "profissao" "text",
    "horario_acordar" time without time zone,
    "horario_dormir" time without time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sexo" character varying(20),
    "data_nascimento" "date",
    "altura_cm" numeric(5,2)
);


ALTER TABLE "public"."saude_e_rotina" OWNER TO "postgres";


COMMENT ON TABLE "public"."saude_e_rotina" IS 'Armazena o histórico de saúde completo e a rotina diária do aluno. São dados de anamnese que mudam com pouca frequência.';



COMMENT ON COLUMN "public"."saude_e_rotina"."aluno_id" IS 'Chave estrangeira para a tabela de alunos.';



COMMENT ON COLUMN "public"."saude_e_rotina"."condicoes_medicas" IS 'Array com condições médicas pré-existentes (ex: {"Hipertensão", "Diabetes tipo 2"}).';



COMMENT ON COLUMN "public"."saude_e_rotina"."medicacoes_em_uso" IS 'JSONB com a lista de medicamentos, doses e frequências (ex: [{"nome": "Losartana", "dose": "50mg"}]).';



COMMENT ON COLUMN "public"."saude_e_rotina"."alergias" IS 'Array com alergias conhecidas, tanto alimentares quanto outras.';



COMMENT ON COLUMN "public"."saude_e_rotina"."lesoes_limitacoes" IS 'JSONB com lesões ou limitações físicas que impactam o treino (ex: [{"local": "Joelho Direito", "descricao": "Tendinite patelar"}]).';



COMMENT ON COLUMN "public"."saude_e_rotina"."profissao" IS 'Profissão do aluno, para entender o nível de atividade diária (NEAT).';



COMMENT ON COLUMN "public"."saude_e_rotina"."horario_acordar" IS 'Horário que o aluno costuma acordar.';



COMMENT ON COLUMN "public"."saude_e_rotina"."horario_dormir" IS 'Horário que o aluno costuma dormir.';



COMMENT ON COLUMN "public"."saude_e_rotina"."sexo" IS 'Sexo biológico do aluno, essencial para cálculos de TMB.';



COMMENT ON COLUMN "public"."saude_e_rotina"."data_nascimento" IS 'Data de nascimento do aluno, para cálculo preciso da idade.';



COMMENT ON COLUMN "public"."saude_e_rotina"."altura_cm" IS 'Altura do aluno em centímetros. Dado de anamnese fundamental.';



CREATE TABLE IF NOT EXISTS "public"."subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "plan_type" character varying(20) NOT NULL,
    "status" character varying(20) DEFAULT 'trial'::character varying NOT NULL,
    "valor_centavos" integer NOT NULL,
    "external_subscription_id" character varying(255),
    "payment_gateway" character varying(50),
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_proxima_cobranca" "date" NOT NULL,
    "data_cancelamento" "date",
    "motivo_cancelamento" "text",
    "auto_renovacao" boolean DEFAULT true NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "subscriptions_plan_type_check" CHECK ((("plan_type")::"text" = ANY ((ARRAY['monthly'::character varying, 'quarterly'::character varying, 'annual'::character varying])::"text"[]))),
    CONSTRAINT "subscriptions_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['trial'::character varying, 'active'::character varying, 'past_due'::character varying, 'cancelled'::character varying, 'expired'::character varying])::"text"[]))),
    CONSTRAINT "subscriptions_valor_centavos_check" CHECK (("valor_centavos" > 0))
);


ALTER TABLE "public"."subscriptions" OWNER TO "postgres";


COMMENT ON TABLE "public"."subscriptions" IS 'Controle de assinaturas e pagamentos dos alunos';



CREATE TABLE IF NOT EXISTS "public"."usage_metrics" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "mensagem_id" "uuid",
    "modelo_utilizado" "text",
    "input_tokens" integer,
    "output_tokens" integer,
    "cached_tokens" integer,
    "web_search_ativado" boolean DEFAULT false,
    "api_response_body" "jsonb"
);


ALTER TABLE "public"."usage_metrics" OWNER TO "postgres";


COMMENT ON TABLE "public"."usage_metrics" IS 'Registra métricas detalhadas de cada chamada à API da OpenAI para fins de análise de custo e performance.';



COMMENT ON COLUMN "public"."usage_metrics"."aluno_id" IS 'ID do aluno que originou a chamada.';



COMMENT ON COLUMN "public"."usage_metrics"."mensagem_id" IS 'ID da mensagem_temporaria que iniciou o processo, para rastreabilidade.';



COMMENT ON COLUMN "public"."usage_metrics"."modelo_utilizado" IS 'O modelo da OpenAI que foi utilizado na chamada (ex: "gpt-4o").';



COMMENT ON COLUMN "public"."usage_metrics"."input_tokens" IS 'Número de tokens de entrada enviados (prompt + mensagem).';



COMMENT ON COLUMN "public"."usage_metrics"."output_tokens" IS 'Número de tokens de saída gerados pela IA.';



COMMENT ON COLUMN "public"."usage_metrics"."cached_tokens" IS 'Número de tokens de entrada que foram aproveitados do cache da API, se aplicável.';



COMMENT ON COLUMN "public"."usage_metrics"."web_search_ativado" IS 'Indica se a ferramenta "web_search" foi utilizada pela IA nesta chamada.';



COMMENT ON COLUMN "public"."usage_metrics"."api_response_body" IS 'Armazena o corpo JSON completo da resposta da API da OpenAI para auditoria e futuras análises.';



CREATE OR REPLACE VIEW "public"."vw_completions_aguardando_processamento" AS
 SELECT "c"."id",
    "c"."aluno_id",
    "a"."nome_completo",
    "a"."whatsapp",
    "c"."created_at",
    (EXTRACT(epoch FROM ("now"() - "c"."created_at")))::integer AS "segundos_desde_criacao",
    "jsonb_array_length"("c"."history") AS "total_mensagens",
    ("c"."history" -> '-1'::integer) AS "ultima_mensagem"
   FROM ("public"."completions_old" "c"
     JOIN "public"."alunos" "a" ON (("c"."aluno_id" = "a"."id")))
  WHERE ("c"."processado" = false)
  ORDER BY "c"."created_at";


ALTER VIEW "public"."vw_completions_aguardando_processamento" OWNER TO "postgres";


COMMENT ON VIEW "public"."vw_completions_aguardando_processamento" IS 'Completions não processados aguardando LLM.';



CREATE OR REPLACE VIEW "public"."vw_mensagens_aguardando_agregacao" AS
 SELECT "mt"."id",
    "mt"."aluno_id",
    "a"."nome_completo",
    "mt"."whatsapp",
    "mt"."mensagem",
    "mt"."tipo",
    "mt"."timestamp_mensagem",
    "mt"."timestamp_recebimento",
    (EXTRACT(epoch FROM ("now"() - "mt"."timestamp_recebimento")))::integer AS "segundos_desde_recebimento",
    ("count"(*) OVER (PARTITION BY "mt"."aluno_id"))::integer AS "total_mensagens_pendentes"
   FROM ("public"."mensagens_temporarias" "mt"
     LEFT JOIN "public"."alunos" "a" ON (("mt"."aluno_id" = "a"."id")))
  WHERE ("mt"."agregado" = false)
  ORDER BY "mt"."aluno_id", "mt"."timestamp_recebimento";


ALTER VIEW "public"."vw_mensagens_aguardando_agregacao" OWNER TO "postgres";


COMMENT ON VIEW "public"."vw_mensagens_aguardando_agregacao" IS 'Mensagens aguardando agregação com métricas.';



CREATE MATERIALIZED VIEW "public"."vw_metricas_diarias_por_aluno" AS
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    "date"("um"."created_at") AS "data",
    "count"(*) AS "total_chamadas",
    "sum"("um"."input_tokens") AS "total_input_tokens",
    "sum"("um"."output_tokens") AS "total_output_tokens",
    COALESCE("sum"("um"."cached_tokens"), (0)::bigint) AS "total_cached_tokens",
    ("sum"("um"."input_tokens") - COALESCE("sum"("um"."cached_tokens"), (0)::bigint)) AS "input_tokens_faturados",
    (((((("sum"("um"."input_tokens") - COALESCE("sum"("um"."cached_tokens"), (0)::bigint)))::numeric * 2.0) / (1000000)::numeric) + ((("sum"("um"."output_tokens"))::numeric * 12.0) / (1000000)::numeric)) + (((COALESCE("sum"("um"."cached_tokens"), (0)::bigint))::numeric * 0.15) / (1000000)::numeric)) AS "gasto_diario_usd"
   FROM ("public"."usage_metrics" "um"
     JOIN "public"."alunos" "a" ON (("um"."aluno_id" = "a"."id")))
  GROUP BY "a"."id", "a"."nome_completo", ("date"("um"."created_at"))
  ORDER BY ("date"("um"."created_at")) DESC, "a"."nome_completo"
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."vw_metricas_diarias_por_aluno" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "public"."vw_metricas_diarias_por_aluno" IS 'Visão materializada que consolida diariamente o uso de tokens e calcula o custo detalhado (input, output, cache) para cada aluno.';



CREATE TABLE IF NOT EXISTS "public"."workout_exercises" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workout_id" "uuid" NOT NULL,
    "ordem" smallint,
    "nome_exercicio" character varying(255) NOT NULL,
    "series" character varying(20),
    "repeticoes" character varying(20),
    "carga_kg" numeric,
    "descanso_segundos" smallint,
    "observacoes" "text"
);


ALTER TABLE "public"."workout_exercises" OWNER TO "postgres";


COMMENT ON TABLE "public"."workout_exercises" IS 'Detalha cada exercício dentro de um treino específico, permitindo fácil atualização de cargas e outros parâmetros.';



COMMENT ON COLUMN "public"."workout_exercises"."carga_kg" IS 'A carga recomendada para o exercício. Este campo será frequentemente atualizado.';



CREATE TABLE IF NOT EXISTS "public"."workout_plans_old" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "nome_programa" character varying(255) NOT NULL,
    "tipo_divisao" character varying(50) NOT NULL,
    "frequencia_semanal" integer NOT NULL,
    "divisao_semanal" "jsonb" NOT NULL,
    "notas" "text",
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_fim" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "workout_plans_frequencia_semanal_check" CHECK ((("frequencia_semanal" >= 3) AND ("frequencia_semanal" <= 6)))
);


ALTER TABLE "public"."workout_plans_old" OWNER TO "postgres";


COMMENT ON TABLE "public"."workout_plans_old" IS 'Tabela depreciada em 13/10/2025. Os dados foram migrados para a nova estrutura relacional (`workout_programs`, `program_workouts`, `workout_exercises`). Será removida em uma futura migração.';



CREATE TABLE IF NOT EXISTS "public"."workout_programs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "nome_programa" character varying(255) NOT NULL,
    "objetivo" "text",
    "frequencia_semanal" smallint,
    "duracao_sessao_min" smallint,
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_fim" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."workout_programs" OWNER TO "postgres";


COMMENT ON TABLE "public"."workout_programs" IS 'Tabela mestre para um programa de treino. Contém os metadados gerais do programa ativo ou de versões anteriores.';



COMMENT ON COLUMN "public"."workout_programs"."nome_programa" IS 'Nome do programa (ex: "Hipertrofia Upper/Lower 4x").';



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_whatsapp_key" UNIQUE ("whatsapp");



ALTER TABLE ONLY "public"."body_metrics"
    ADD CONSTRAINT "body_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."completions_old"
    ADD CONSTRAINT "completions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."config_sistema"
    ADD CONSTRAINT "config_sistema_pkey" PRIMARY KEY ("chave");



ALTER TABLE ONLY "public"."daily_consumption_history"
    ADD CONSTRAINT "daily_consumption_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_workout_logs"
    ADD CONSTRAINT "daily_workout_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."diet_plans"
    ADD CONSTRAINT "diet_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dynamic_prompts"
    ADD CONSTRAINT "dynamic_prompts_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."dynamic_prompts_old"
    ADD CONSTRAINT "dynamic_prompts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dynamic_prompts"
    ADD CONSTRAINT "dynamic_prompts_pkey1" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."goals"
    ADD CONSTRAINT "goals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."historico_atualizacoes_exercicio"
    ADD CONSTRAINT "historico_atualizacoes_exercicio_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."instrucoes_nutricionista"
    ADD CONSTRAINT "instrucoes_nutricionista_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."instrucoes_nutricionista"
    ADD CONSTRAINT "instrucoes_nutricionista_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."instrucoes_personal"
    ADD CONSTRAINT "instrucoes_personal_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."instrucoes_personal"
    ADD CONSTRAINT "instrucoes_personal_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."logs_funcoes"
    ADD CONSTRAINT "logs_funcoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mensagens_temporarias"
    ADD CONSTRAINT "mensagens_temporarias_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_transactions"
    ADD CONSTRAINT "payment_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preferences_old"
    ADD CONSTRAINT "preferences_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."preferences_old"
    ADD CONSTRAINT "preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preferencias_alimentares"
    ADD CONSTRAINT "preferencias_alimentares_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."preferencias_alimentares"
    ADD CONSTRAINT "preferencias_alimentares_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preferencias_treino"
    ADD CONSTRAINT "preferencias_treino_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."preferencias_treino"
    ADD CONSTRAINT "preferencias_treino_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."processed_webhook_messages"
    ADD CONSTRAINT "processed_webhook_messages_message_id_key" UNIQUE ("message_id");



ALTER TABLE ONLY "public"."processed_webhook_messages"
    ADD CONSTRAINT "processed_webhook_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."program_workouts"
    ADD CONSTRAINT "program_workouts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saude_e_rotina"
    ADD CONSTRAINT "saude_e_rotina_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."saude_e_rotina"
    ADD CONSTRAINT "saude_e_rotina_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usage_metrics"
    ADD CONSTRAINT "usage_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workout_exercises"
    ADD CONSTRAINT "workout_exercises_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workout_plans_old"
    ADD CONSTRAINT "workout_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workout_programs"
    ADD CONSTRAINT "workout_programs_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_alunos_created_at" ON "public"."alunos" USING "btree" ("created_at");



CREATE INDEX "idx_alunos_whatsapp" ON "public"."alunos" USING "btree" ("whatsapp");



CREATE INDEX "idx_body_metrics_aluno_id" ON "public"."body_metrics" USING "btree" ("aluno_id");



CREATE INDEX "idx_body_metrics_data_medicao" ON "public"."body_metrics" USING "btree" ("aluno_id", "data_medicao" DESC);



CREATE INDEX "idx_completions_aluno_id" ON "public"."completions_old" USING "btree" ("aluno_id");



CREATE INDEX "idx_completions_created_at" ON "public"."completions_old" USING "btree" ("aluno_id", "created_at" DESC);



CREATE INDEX "idx_completions_nao_processados" ON "public"."completions_old" USING "btree" ("processado", "created_at") WHERE ("processado" = false);



CREATE INDEX "idx_config_sistema_chave" ON "public"."config_sistema" USING "btree" ("chave");



CREATE INDEX "idx_daily_consumption_aluno_id" ON "public"."daily_consumption_history" USING "btree" ("aluno_id");



CREATE INDEX "idx_daily_consumption_data" ON "public"."daily_consumption_history" USING "btree" ("aluno_id", "data_registro" DESC);



CREATE UNIQUE INDEX "idx_daily_consumption_unique_date" ON "public"."daily_consumption_history" USING "btree" ("aluno_id", "data_registro");



CREATE INDEX "idx_daily_workout_aluno_id" ON "public"."daily_workout_logs" USING "btree" ("aluno_id");



CREATE INDEX "idx_daily_workout_data" ON "public"."daily_workout_logs" USING "btree" ("aluno_id", "data_treino" DESC);



CREATE INDEX "idx_diet_plans_active" ON "public"."diet_plans" USING "btree" ("aluno_id", "is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_diet_plans_aluno_id" ON "public"."diet_plans" USING "btree" ("aluno_id");



CREATE UNIQUE INDEX "idx_diet_plans_one_active_per_aluno" ON "public"."diet_plans" USING "btree" ("aluno_id") WHERE ("is_active" = true);



CREATE INDEX "idx_diet_plans_version" ON "public"."diet_plans" USING "btree" ("aluno_id", "version" DESC);



CREATE INDEX "idx_dynamic_prompts_active" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id", "is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_dynamic_prompts_aluno_id" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id");



CREATE INDEX "idx_dynamic_prompts_date" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id", "data_validade" DESC);



CREATE UNIQUE INDEX "idx_dynamic_prompts_unique" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id", "data_validade") WHERE ("is_active" = true);



CREATE INDEX "idx_goals_aluno_id" ON "public"."goals" USING "btree" ("aluno_id");



CREATE UNIQUE INDEX "idx_goals_status_ativo_unico_por_aluno" ON "public"."goals" USING "btree" ("aluno_id") WHERE (("status")::"text" = 'ativo'::"text");



CREATE INDEX "idx_historico_aluno_id" ON "public"."historico_atualizacoes_exercicio" USING "btree" ("aluno_id");



CREATE INDEX "idx_historico_exercicio_id" ON "public"."historico_atualizacoes_exercicio" USING "btree" ("exercicio_id");



CREATE INDEX "idx_historico_timestamp" ON "public"."historico_atualizacoes_exercicio" USING "btree" ("timestamp" DESC);



CREATE INDEX "idx_logs_nome_funcao" ON "public"."logs_funcoes" USING "btree" ("nome_funcao");



CREATE INDEX "idx_logs_timestamp" ON "public"."logs_funcoes" USING "btree" ("timestamp" DESC);



CREATE INDEX "idx_mensagens_temp_agregado" ON "public"."mensagens_temporarias" USING "btree" ("agregado") WHERE ("agregado" = false);



CREATE INDEX "idx_mensagens_temp_aluno_id" ON "public"."mensagens_temporarias" USING "btree" ("aluno_id");



CREATE INDEX "idx_mensagens_temp_para_agregacao" ON "public"."mensagens_temporarias" USING "btree" ("aluno_id", "timestamp_recebimento" DESC) WHERE ("agregado" = false);



CREATE INDEX "idx_mensagens_temp_timestamp" ON "public"."mensagens_temporarias" USING "btree" ("aluno_id", "timestamp_recebimento" DESC);



CREATE INDEX "idx_mensagens_temp_whatsapp" ON "public"."mensagens_temporarias" USING "btree" ("whatsapp");



CREATE INDEX "idx_payment_transactions_aluno" ON "public"."payment_transactions" USING "btree" ("aluno_id");



CREATE INDEX "idx_payment_transactions_created" ON "public"."payment_transactions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_payment_transactions_external_id" ON "public"."payment_transactions" USING "btree" ("external_transaction_id");



CREATE INDEX "idx_payment_transactions_status" ON "public"."payment_transactions" USING "btree" ("status");



CREATE INDEX "idx_payment_transactions_subscription" ON "public"."payment_transactions" USING "btree" ("subscription_id");



CREATE INDEX "idx_preferences_aluno_id" ON "public"."preferences_old" USING "btree" ("aluno_id");



CREATE INDEX "idx_processed_messages_created" ON "public"."processed_webhook_messages" USING "btree" ("processed_at");



CREATE INDEX "idx_processed_messages_id" ON "public"."processed_webhook_messages" USING "btree" ("message_id");



CREATE INDEX "idx_subscriptions_aluno_id" ON "public"."subscriptions" USING "btree" ("aluno_id");



CREATE INDEX "idx_subscriptions_external_id" ON "public"."subscriptions" USING "btree" ("external_subscription_id");



CREATE INDEX "idx_subscriptions_proxima_cobranca" ON "public"."subscriptions" USING "btree" ("data_proxima_cobranca") WHERE (("status")::"text" = 'active'::"text");



CREATE INDEX "idx_subscriptions_status" ON "public"."subscriptions" USING "btree" ("status");



CREATE INDEX "idx_usage_metrics_aluno_id" ON "public"."usage_metrics" USING "btree" ("aluno_id");



CREATE INDEX "idx_usage_metrics_created_at" ON "public"."usage_metrics" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_workout_plans_active" ON "public"."workout_plans_old" USING "btree" ("aluno_id", "is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_workout_plans_aluno_id" ON "public"."workout_plans_old" USING "btree" ("aluno_id");



CREATE UNIQUE INDEX "idx_workout_plans_one_active_per_aluno" ON "public"."workout_plans_old" USING "btree" ("aluno_id") WHERE ("is_active" = true);



CREATE INDEX "idx_workout_plans_version" ON "public"."workout_plans_old" USING "btree" ("aluno_id", "version" DESC);



CREATE OR REPLACE TRIGGER "trigger_achievements_changes" AFTER INSERT OR DELETE ON "public"."achievements" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_body_metrics_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."body_metrics" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_diet_plans_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."diet_plans" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_goals_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."goals" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_preferencias_alimentares_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."preferencias_alimentares" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_preferencias_treino_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."preferencias_treino" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_program_workouts_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."program_workouts" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_saude_e_rotina_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."saude_e_rotina" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_schedule_aggregation" AFTER INSERT ON "public"."mensagens_temporarias" FOR EACH ROW WHEN ((("new"."tipo_mensagem")::"text" = 'RECEBIDA'::"text")) EXECUTE FUNCTION "public"."schedule_aggregation_on_new_message"();



CREATE OR REPLACE TRIGGER "trigger_workout_exercises_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."workout_exercises" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_workout_programs_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."workout_programs" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_goal_id_fkey" FOREIGN KEY ("goal_id") REFERENCES "public"."goals"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."body_metrics"
    ADD CONSTRAINT "body_metrics_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."completions_old"
    ADD CONSTRAINT "completions_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_consumption_history"
    ADD CONSTRAINT "daily_consumption_history_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_workout_logs"
    ADD CONSTRAINT "daily_workout_logs_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."diet_plans"
    ADD CONSTRAINT "diet_plans_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dynamic_prompts_old"
    ADD CONSTRAINT "dynamic_prompts_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dynamic_prompts"
    ADD CONSTRAINT "dynamic_prompts_aluno_id_fkey1" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."goals"
    ADD CONSTRAINT "goals_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."historico_atualizacoes_exercicio"
    ADD CONSTRAINT "historico_atualizacoes_exercicio_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."historico_atualizacoes_exercicio"
    ADD CONSTRAINT "historico_atualizacoes_exercicio_exercicio_id_fkey" FOREIGN KEY ("exercicio_id") REFERENCES "public"."workout_exercises"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."instrucoes_nutricionista"
    ADD CONSTRAINT "instrucoes_nutricionista_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."instrucoes_personal"
    ADD CONSTRAINT "instrucoes_personal_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mensagens_temporarias"
    ADD CONSTRAINT "mensagens_temporarias_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mensagens_temporarias"
    ADD CONSTRAINT "mensagens_temporarias_completion_id_fkey" FOREIGN KEY ("completion_id") REFERENCES "public"."completions_old"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payment_transactions"
    ADD CONSTRAINT "payment_transactions_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_transactions"
    ADD CONSTRAINT "payment_transactions_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."subscriptions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preferences_old"
    ADD CONSTRAINT "preferences_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preferencias_alimentares"
    ADD CONSTRAINT "preferencias_alimentares_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preferencias_treino"
    ADD CONSTRAINT "preferencias_treino_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."processed_webhook_messages"
    ADD CONSTRAINT "processed_webhook_messages_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_workouts"
    ADD CONSTRAINT "program_workouts_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."workout_programs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."saude_e_rotina"
    ADD CONSTRAINT "saude_e_rotina_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usage_metrics"
    ADD CONSTRAINT "usage_metrics_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usage_metrics"
    ADD CONSTRAINT "usage_metrics_mensagem_id_fkey" FOREIGN KEY ("mensagem_id") REFERENCES "public"."mensagens_temporarias"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."workout_exercises"
    ADD CONSTRAINT "workout_exercises_workout_id_fkey" FOREIGN KEY ("workout_id") REFERENCES "public"."program_workouts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."workout_plans_old"
    ADD CONSTRAINT "workout_plans_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."workout_programs"
    ADD CONSTRAINT "workout_programs_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



CREATE POLICY "Service role can read config" ON "public"."config_sistema" FOR SELECT TO "service_role" USING (true);



ALTER TABLE "public"."config_sistema" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;

























































































































































GRANT ALL ON FUNCTION "public"."agregar_mensagens"() TO "anon";
GRANT ALL ON FUNCTION "public"."agregar_mensagens"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."agregar_mensagens"() TO "service_role";



GRANT ALL ON FUNCTION "public"."agregar_mensagens_para_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."agregar_mensagens_para_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."agregar_mensagens_para_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_old_processed_messages"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_old_processed_messages"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_old_processed_messages"() TO "service_role";



GRANT ALL ON FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_dynamic_prompt_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_dynamic_prompt_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_dynamic_prompt_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."invoke_testar_extracao_edge_function"() TO "anon";
GRANT ALL ON FUNCTION "public"."invoke_testar_extracao_edge_function"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."invoke_testar_extracao_edge_function"() TO "service_role";



GRANT ALL ON FUNCTION "public"."limpar_completions_antigos"() TO "anon";
GRANT ALL ON FUNCTION "public"."limpar_completions_antigos"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."limpar_completions_antigos"() TO "service_role";



GRANT ALL ON FUNCTION "public"."limpar_mensagens_temporarias"() TO "anon";
GRANT ALL ON FUNCTION "public"."limpar_mensagens_temporarias"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."limpar_mensagens_temporarias"() TO "service_role";



GRANT ALL ON FUNCTION "public"."obter_resumo_diario"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."obter_resumo_diario"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obter_resumo_diario"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."processar_confirmacao_refeicao"("p_registro_id" "uuid", "p_confirmar" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."processar_confirmacao_refeicao"("p_registro_id" "uuid", "p_confirmar" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."processar_confirmacao_refeicao"("p_registro_id" "uuid", "p_confirmar" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."processar_macros_diarios_para_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."processar_macros_diarios_para_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."processar_macros_diarios_para_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."propor_atualizacao_carga"("p_exercicio_id" "uuid", "p_variacao_kg" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."propor_atualizacao_carga"("p_exercicio_id" "uuid", "p_variacao_kg" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."propor_atualizacao_carga"("p_exercicio_id" "uuid", "p_variacao_kg" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."propor_registro_refeicao"("p_aluno_id" "uuid", "p_refeicao" "text", "p_tipo" "text", "p_calorias" numeric, "p_proteinas" numeric, "p_carboidratos" numeric, "p_gorduras" numeric, "p_liquidos_ml" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."propor_registro_refeicao"("p_aluno_id" "uuid", "p_refeicao" "text", "p_tipo" "text", "p_calorias" numeric, "p_proteinas" numeric, "p_carboidratos" numeric, "p_gorduras" numeric, "p_liquidos_ml" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."propor_registro_refeicao"("p_aluno_id" "uuid", "p_refeicao" "text", "p_tipo" "text", "p_calorias" numeric, "p_proteinas" numeric, "p_carboidratos" numeric, "p_gorduras" numeric, "p_liquidos_ml" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."rebuild_conquistas_recentes_json"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_conquistas_recentes_json"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_conquistas_recentes_json"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rebuild_plano_alimentar_json"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_plano_alimentar_json"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_plano_alimentar_json"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rebuild_plano_treino_json"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_plano_treino_json"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_plano_treino_json"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rebuild_prompt_final"() TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_prompt_final"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_prompt_final"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rebuild_saude_e_rotina_json"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_saude_e_rotina_json"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_saude_e_rotina_json"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."schedule_aggregation_on_new_message"() TO "anon";
GRANT ALL ON FUNCTION "public"."schedule_aggregation_on_new_message"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."schedule_aggregation_on_new_message"() TO "service_role";



GRANT ALL ON FUNCTION "public"."testar_edge_propor_refeicao"() TO "anon";
GRANT ALL ON FUNCTION "public"."testar_edge_propor_refeicao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."testar_edge_propor_refeicao"() TO "service_role";



GRANT ALL ON FUNCTION "public"."testar_envio_whatsapp"() TO "anon";
GRANT ALL ON FUNCTION "public"."testar_envio_whatsapp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."testar_envio_whatsapp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."testar_extrator_texto"() TO "anon";
GRANT ALL ON FUNCTION "public"."testar_extrator_texto"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."testar_extrator_texto"() TO "service_role";



GRANT ALL ON FUNCTION "public"."testar_proposta_carga"("p_aluno_id" "uuid", "p_nome_exercicio" "text", "p_variacao_kg" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."testar_proposta_carga"("p_aluno_id" "uuid", "p_nome_exercicio" "text", "p_variacao_kg" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."testar_proposta_carga"("p_aluno_id" "uuid", "p_nome_exercicio" "text", "p_variacao_kg" numeric) TO "service_role";












SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;









GRANT ALL ON TABLE "public"."achievements" TO "anon";
GRANT ALL ON TABLE "public"."achievements" TO "authenticated";
GRANT ALL ON TABLE "public"."achievements" TO "service_role";



GRANT ALL ON TABLE "public"."alunos" TO "anon";
GRANT ALL ON TABLE "public"."alunos" TO "authenticated";
GRANT ALL ON TABLE "public"."alunos" TO "service_role";



GRANT ALL ON TABLE "public"."body_metrics" TO "anon";
GRANT ALL ON TABLE "public"."body_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."body_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."completions_old" TO "anon";
GRANT ALL ON TABLE "public"."completions_old" TO "authenticated";
GRANT ALL ON TABLE "public"."completions_old" TO "service_role";



GRANT ALL ON TABLE "public"."config_sistema" TO "anon";
GRANT ALL ON TABLE "public"."config_sistema" TO "authenticated";
GRANT ALL ON TABLE "public"."config_sistema" TO "service_role";



GRANT ALL ON TABLE "public"."daily_consumption_history" TO "anon";
GRANT ALL ON TABLE "public"."daily_consumption_history" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_consumption_history" TO "service_role";



GRANT ALL ON TABLE "public"."daily_workout_logs" TO "anon";
GRANT ALL ON TABLE "public"."daily_workout_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_workout_logs" TO "service_role";



GRANT ALL ON TABLE "public"."diet_plans" TO "anon";
GRANT ALL ON TABLE "public"."diet_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."diet_plans" TO "service_role";



GRANT ALL ON TABLE "public"."dynamic_prompts" TO "anon";
GRANT ALL ON TABLE "public"."dynamic_prompts" TO "authenticated";
GRANT ALL ON TABLE "public"."dynamic_prompts" TO "service_role";



GRANT ALL ON TABLE "public"."dynamic_prompts_old" TO "anon";
GRANT ALL ON TABLE "public"."dynamic_prompts_old" TO "authenticated";
GRANT ALL ON TABLE "public"."dynamic_prompts_old" TO "service_role";



GRANT ALL ON TABLE "public"."goals" TO "anon";
GRANT ALL ON TABLE "public"."goals" TO "authenticated";
GRANT ALL ON TABLE "public"."goals" TO "service_role";



GRANT ALL ON TABLE "public"."historico_atualizacoes_exercicio" TO "anon";
GRANT ALL ON TABLE "public"."historico_atualizacoes_exercicio" TO "authenticated";
GRANT ALL ON TABLE "public"."historico_atualizacoes_exercicio" TO "service_role";



GRANT ALL ON TABLE "public"."instrucoes_nutricionista" TO "anon";
GRANT ALL ON TABLE "public"."instrucoes_nutricionista" TO "authenticated";
GRANT ALL ON TABLE "public"."instrucoes_nutricionista" TO "service_role";



GRANT ALL ON TABLE "public"."instrucoes_personal" TO "anon";
GRANT ALL ON TABLE "public"."instrucoes_personal" TO "authenticated";
GRANT ALL ON TABLE "public"."instrucoes_personal" TO "service_role";



GRANT ALL ON TABLE "public"."logs_funcoes" TO "anon";
GRANT ALL ON TABLE "public"."logs_funcoes" TO "authenticated";
GRANT ALL ON TABLE "public"."logs_funcoes" TO "service_role";



GRANT ALL ON TABLE "public"."mensagens_temporarias" TO "anon";
GRANT ALL ON TABLE "public"."mensagens_temporarias" TO "authenticated";
GRANT ALL ON TABLE "public"."mensagens_temporarias" TO "service_role";



GRANT ALL ON TABLE "public"."payment_transactions" TO "anon";
GRANT ALL ON TABLE "public"."payment_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."preferences_old" TO "anon";
GRANT ALL ON TABLE "public"."preferences_old" TO "authenticated";
GRANT ALL ON TABLE "public"."preferences_old" TO "service_role";



GRANT ALL ON TABLE "public"."preferencias_alimentares" TO "anon";
GRANT ALL ON TABLE "public"."preferencias_alimentares" TO "authenticated";
GRANT ALL ON TABLE "public"."preferencias_alimentares" TO "service_role";



GRANT ALL ON TABLE "public"."preferencias_treino" TO "anon";
GRANT ALL ON TABLE "public"."preferencias_treino" TO "authenticated";
GRANT ALL ON TABLE "public"."preferencias_treino" TO "service_role";



GRANT ALL ON TABLE "public"."processed_webhook_messages" TO "anon";
GRANT ALL ON TABLE "public"."processed_webhook_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."processed_webhook_messages" TO "service_role";



GRANT ALL ON TABLE "public"."program_workouts" TO "anon";
GRANT ALL ON TABLE "public"."program_workouts" TO "authenticated";
GRANT ALL ON TABLE "public"."program_workouts" TO "service_role";



GRANT ALL ON TABLE "public"."saude_e_rotina" TO "anon";
GRANT ALL ON TABLE "public"."saude_e_rotina" TO "authenticated";
GRANT ALL ON TABLE "public"."saude_e_rotina" TO "service_role";



GRANT ALL ON TABLE "public"."subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."usage_metrics" TO "anon";
GRANT ALL ON TABLE "public"."usage_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."usage_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."vw_completions_aguardando_processamento" TO "anon";
GRANT ALL ON TABLE "public"."vw_completions_aguardando_processamento" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_completions_aguardando_processamento" TO "service_role";



GRANT ALL ON TABLE "public"."vw_mensagens_aguardando_agregacao" TO "anon";
GRANT ALL ON TABLE "public"."vw_mensagens_aguardando_agregacao" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_mensagens_aguardando_agregacao" TO "service_role";



GRANT ALL ON TABLE "public"."vw_metricas_diarias_por_aluno" TO "anon";
GRANT ALL ON TABLE "public"."vw_metricas_diarias_por_aluno" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_metricas_diarias_por_aluno" TO "service_role";



GRANT ALL ON TABLE "public"."workout_exercises" TO "anon";
GRANT ALL ON TABLE "public"."workout_exercises" TO "authenticated";
GRANT ALL ON TABLE "public"."workout_exercises" TO "service_role";



GRANT ALL ON TABLE "public"."workout_plans_old" TO "anon";
GRANT ALL ON TABLE "public"."workout_plans_old" TO "authenticated";
GRANT ALL ON TABLE "public"."workout_plans_old" TO "service_role";



GRANT ALL ON TABLE "public"."workout_programs" TO "anon";
GRANT ALL ON TABLE "public"."workout_programs" TO "authenticated";
GRANT ALL ON TABLE "public"."workout_programs" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























\unrestrict 2GfBbM5FdVXzmCFOhF0HupDU0ZPanlg7wkpaBSYcpA8eKTuztrdkdSCwOs6mzEa

RESET ALL;
