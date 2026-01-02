
\restrict ghtMjOwdpAceXnvldrhCdNvKsyVnFRES8ZRcWvaUutPBxuSw3aDCTfu3evH0arv


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






CREATE TYPE "public"."status_onboarding" AS ENUM (
    'aguardando_analise',
    'em_revisao',
    'aprovado',
    'rejeitado'
);


ALTER TYPE "public"."status_onboarding" OWNER TO "postgres";


COMMENT ON TYPE "public"."status_onboarding" IS 'Status do processo de onboarding e aprovação de novos alunos';



CREATE TYPE "public"."tipo_profissional" AS ENUM (
    'nutricionista',
    'personal',
    'master'
);


ALTER TYPE "public"."tipo_profissional" OWNER TO "postgres";


COMMENT ON TYPE "public"."tipo_profissional" IS 'Tipo de especialidade: nutricionista, personal ou master (nutri+personal)';



CREATE TYPE "public"."user_role" AS ENUM (
    'aluno',
    'nutricionista',
    'personal',
    'master',
    'dev'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


COMMENT ON TYPE "public"."user_role" IS 'Papéis disponíveis: aluno (padrão), nutricionista, personal, master (nutri+personal), dev (acesso total)';



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


CREATE OR REPLACE FUNCTION "public"."aprovar_onboarding"("p_onboarding_id" "uuid", "p_aprovado_por_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_onboarding_record RECORD;
    v_aluno_id UUID;
BEGIN
    -- 1. Verificar se o registro de onboarding existe e está pendente/aguardando
    SELECT * INTO v_onboarding_record
    FROM public.onboarding_pendente
    WHERE id = p_onboarding_id
      AND status IN ('aguardando_analise', 'em_revisao'); -- Só pode aprovar se não estiver rejeitado/concluído

    IF v_onboarding_record IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Onboarding não encontrado ou status inválido para aprovação.'
        );
    END IF;

    v_aluno_id := v_onboarding_record.aluno_id;

    -- 2. Validar se quem está aprovando é o responsável (Opcional mas recomendado)
    -- Aqui assumimos que o frontend já validou a permissão, mas no backend é mais seguro.
    -- Para simplificar o MVP, vamos confiar que p_aprovado_por_id é válido.

    -- 3. Atualizar o status na tabela onboarding_pendente
    UPDATE public.onboarding_pendente
    SET 
        status = 'aprovado',
        aprovado_por_id = p_aprovado_por_id,
        data_aprovacao = NOW(),
        updated_at = NOW()
    WHERE id = p_onboarding_id;

    -- 4. (Opcional) Atualizar o status do aluno na tabela 'alunos' se necessário
    -- Ex: Mudar de 'trial' para 'active' se a aprovação for o gatilho
    -- UPDATE public.alunos SET subscription_status = 'active' WHERE id = v_aluno_id;

    -- 5. Retorno
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Onboarding aprovado com sucesso.',
        'aluno_id', v_aluno_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro ao aprovar onboarding: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."aprovar_onboarding"("p_onboarding_id" "uuid", "p_aprovado_por_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."atualizar_peso_aluno"("p_aluno_id" "uuid", "p_novo_peso" numeric, "p_data_medicao" "date" DEFAULT CURRENT_DATE, "p_notas" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "peso_anterior" numeric, "peso_novo" numeric, "diferenca" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_ultimo_registro RECORD;
    v_novo_id UUID;
BEGIN
    -- Buscar o último registro de medição
    SELECT *
    INTO v_ultimo_registro
    FROM public.body_metrics
    WHERE aluno_id = p_aluno_id
    ORDER BY data_medicao DESC, created_at DESC
    LIMIT 1;

    -- Se não existe registro anterior, criar o primeiro
    IF v_ultimo_registro IS NULL THEN
        INSERT INTO public.body_metrics (
            aluno_id,
            peso_kg,
            data_medicao,
            notas
        )
        VALUES (
            p_aluno_id,
            p_novo_peso,
            p_data_medicao,
            COALESCE(p_notas, 'Primeira medição')
        )
        RETURNING body_metrics.id INTO v_novo_id;

        RETURN QUERY
        SELECT 
            v_novo_id,
            NULL::NUMERIC as peso_anterior,
            p_novo_peso as peso_novo,
            NULL::NUMERIC as diferenca;
    ELSE
        -- Copiar o registro anterior e atualizar com novo peso
        INSERT INTO public.body_metrics (
            aluno_id,
            peso_kg,
            altura_cm,
            circunferencia_pescoco_cm,
            circunferencia_cintura_cm,
            circunferencia_quadril_cm,
            circunferencia_peito_cm,
            percentual_gordura,
            fotos_urls,
            medidas_json,
            feedback_subjetivo,
            data_medicao,
            notas
        )
        VALUES (
            p_aluno_id,
            p_novo_peso,
            v_ultimo_registro.altura_cm,
            v_ultimo_registro.circunferencia_pescoco_cm,
            v_ultimo_registro.circunferencia_cintura_cm,
            v_ultimo_registro.circunferencia_quadril_cm,
            v_ultimo_registro.circunferencia_peito_cm,
            v_ultimo_registro.percentual_gordura,
            v_ultimo_registro.fotos_urls,
            v_ultimo_registro.medidas_json,
            v_ultimo_registro.feedback_subjetivo,
            p_data_medicao,
            COALESCE(p_notas, 'Atualização de peso')
        )
        RETURNING body_metrics.id INTO v_novo_id;

        RETURN QUERY
        SELECT 
            v_novo_id,
            v_ultimo_registro.peso_kg as peso_anterior,
            p_novo_peso as peso_novo,
            (p_novo_peso - v_ultimo_registro.peso_kg) as diferenca;
    END IF;
END;
$$;


ALTER FUNCTION "public"."atualizar_peso_aluno"("p_aluno_id" "uuid", "p_novo_peso" numeric, "p_data_medicao" "date", "p_notas" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."atualizar_peso_aluno"("p_aluno_id" "uuid", "p_novo_peso" numeric, "p_data_medicao" "date", "p_notas" "text") IS 'Atualiza o peso do aluno. Copia todos os dados da última medição e atualiza apenas o peso. Retorna peso anterior, novo e diferença.';



CREATE OR REPLACE FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_prompt_record RECORD;
    v_prompt_final_text TEXT;
    v_prompt_introducao TEXT;
    v_prompt_persona TEXT;
    v_prompt_finais TEXT;
BEGIN
    RAISE NOTICE '[Atualizador Manual] Iniciando a reconstrução do prompt para o aluno ID: %', p_aluno_id;

    -- 1. Busca TODOS os prompts estáticos da config
    SELECT valor INTO v_prompt_introducao FROM public.config_sistema WHERE chave = 'prompt_introducao';
    SELECT valor INTO v_prompt_persona FROM public.config_sistema WHERE chave = 'prompt_base_ia';
    SELECT valor INTO v_prompt_finais FROM public.config_sistema WHERE chave = 'prompt_consideracoes_finais';

    -- 2. Busca todos os blocos de contexto da tabela dynamic_prompts
    SELECT * INTO v_prompt_record
    FROM public.dynamic_prompts
    WHERE aluno_id = p_aluno_id;

    IF NOT FOUND THEN
        RAISE WARNING '[Atualizador Manual] Nenhum registro encontrado em dynamic_prompts para o aluno ID: %', p_aluno_id;
        RETURN 'ERRO: Aluno não encontrado em dynamic_prompts.';
    END IF;

    -- 3. Concatena todos os blocos para formar o prompt final (ORDEM CORRIGIDA)
    v_prompt_final_text := CONCAT(
        COALESCE(v_prompt_introducao, ''), E'\n\n',
        COALESCE(v_prompt_persona, ''),
        E'\n\n---\n\n# CAMADA 2: CONTEXTO DINÂMICO DO ALUNO\n\n',
        '## SAÚDE E ROTINA:', E'\n', COALESCE(v_prompt_record.saude_e_rotina_json::text, '{}'), E'\n\n',
        '## OBJETIVO ATIVO E PROGRESSO:', E'\n', COALESCE(v_prompt_record.objetivo_ativo_json::text, '{}'), E'\n\n',
        '## PLANO ALIMENTAR E PREFERÊNCIAS:', E'\n', COALESCE(v_prompt_record.plano_alimentar_json::text, '{}'), E'\n\n',
        '## PLANO DE TREINO (PROGRAMA SEMANAL):', E'\n', COALESCE(v_prompt_record.plano_treino_json::text, '{}'), E'\n\n',
        '## CONQUISTAS RECENTES:', E'\n', COALESCE(v_prompt_record.conquistas_recentes_json::text, '[]'), E'\n\n',
        '## INSTRUÇÕES DO NUTRICIONISTA:', E'\n', COALESCE(v_prompt_record.instrucoes_nutricionista_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## INSTRUÇÕES DO PERSONAL TRAINER:', E'\n', COALESCE(v_prompt_record.instrucoes_personal_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## CONSIDERAÇÕES FINAIS:', E'\n', COALESCE(v_prompt_finais, '') -- <<-- CORRIGIDO: NO FINAL
    );

    -- 4. Atualiza a coluna prompt_final com o texto recém-criado
    UPDATE public.dynamic_prompts
    SET prompt_final = v_prompt_final_text
    WHERE aluno_id = p_aluno_id;

    RAISE NOTICE '[Atualizador Manual] ✅ Prompt final para o aluno ID: % foi atualizado com sucesso.', p_aluno_id;
    RETURN 'Prompt final atualizado com sucesso.';
END;
$$;


ALTER FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atualizar_resumo_completo_aluno"("p_aluno_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_resumo_nutricao JSONB;
    v_resumo_treino JSONB;
    v_resumo_peso JSONB;
    v_cabecalho TEXT;
    v_resultado_final TEXT;
BEGIN
    -- Cabeçalho
    v_cabecalho := '# RELATÓRIO DE DESEMPENHO

Dados consolidados de progresso em três períodos: **semana atual** (em andamento), **semana passada** e **mês passado**.

**Nutrição:** Percentuais de aderência do aluno ao plano nutricional em cada período. Valores entre 80-120% indicam consumo dentro do planejado.

**Treino:** Número de treinos realizados vs planejados, dias que treinou e percentual de aderência. Status classifica o desempenho (completo, bom, regular, baixo).

**Peso:** Evolução desde o início do objetivo até a última medição, mostrando progresso real em kg rumo à meta.


';

    -- NUTRIÇÃO
    SELECT jsonb_build_object(
        'mes_passado', (
            SELECT jsonb_build_object(
                'calorias_percent', COALESCE(percentual_calorias, 0),
                'proteina_percent', COALESCE(percentual_proteina, 0),
                'carbo_percent', COALESCE(percentual_carboidratos, 0),
                'gordura_percent', COALESCE(percentual_gorduras, 0),
                'liquido_percent', COALESCE(percentual_agua, 0)
            )
            FROM public.vw_nutricao_resumo_mensal
            WHERE aluno_id = p_aluno_id
              AND mes_inicio = DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE
        ),
        'semana_passada', (
            SELECT jsonb_build_object(
                'calorias_percent', COALESCE(percentual_calorias, 0),
                'proteina_percent', COALESCE(percentual_proteina, 0),
                'carbo_percent', COALESCE(percentual_carboidratos, 0),
                'gordura_percent', COALESCE(percentual_gorduras, 0),
                'liquido_percent', COALESCE(percentual_agua, 0)
            )
            FROM public.vw_nutricao_resumo_semanal
            WHERE aluno_id = p_aluno_id
              AND semana_inicio = DATE_TRUNC('week', CURRENT_DATE - INTERVAL '1 week')::DATE
        ),
        'semana_atual', (
            SELECT jsonb_object_agg(
                EXTRACT(DOW FROM data_registro)::TEXT,
                jsonb_build_object(
                    'calorias_percent', percentual_calorias,
                    'proteina_percent', percentual_proteina,
                    'carbo_percent', percentual_carboidratos,
                    'gordura_percent', percentual_gorduras,
                    'liquido_percent', percentual_agua
                )
            )
            FROM public.vw_nutricao_resumo_diario
            WHERE aluno_id = p_aluno_id
              AND data_registro >= DATE_TRUNC('week', CURRENT_DATE)::DATE
              AND data_registro <= CURRENT_DATE
        )
    ) INTO v_resumo_nutricao;

    -- TREINO
    SELECT jsonb_build_object(
        'mes_passado', (
            SELECT jsonb_build_object(
                'periodo', TO_CHAR(mes_inicio, 'Month/YYYY'),
                'aderencia', percentual_aderencia || '%',
                'treinos_planejados', treinos_planejados_mes,
                'treinos_realizados', treinos_executados,
                'dias_treinou', dias_treinou,
                'status', status_mes
            )
            FROM public.vw_treino_resumo_mensal
            WHERE aluno_id = p_aluno_id
              AND mes_inicio = DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE
        ),
        'semana_passada', (
            SELECT jsonb_build_object(
                'periodo', semana_inicio || ' a ' || semana_fim,
                'aderencia', percentual_aderencia || '%',
                'treinos_planejados', total_treinos_programa,
                'treinos_realizados', treinos_executados,
                'dias_treinou', dias_treinou,
                'status', status_semana
            )
            FROM public.vw_treino_resumo_semanal
            WHERE aluno_id = p_aluno_id
              AND semana_inicio = DATE_TRUNC('week', CURRENT_DATE - INTERVAL '1 week')::DATE
        ),
        'semana_atual', (
            SELECT jsonb_build_object(
                'periodo', semana_inicio || ' a ' || semana_fim,
                'aderencia', percentual_aderencia || '%',
                'treinos_planejados', total_treinos_programa,
                'treinos_realizados', treinos_executados,
                'dias_treinou', dias_treinou,
                'status', status_semana
            )
            FROM public.vw_treino_resumo_semanal
            WHERE aluno_id = p_aluno_id
              AND semana_inicio = DATE_TRUNC('week', CURRENT_DATE)::DATE
        )
    ) INTO v_resumo_treino;

    -- PESO
    SELECT jsonb_build_object(
        'peso_atual', (
            SELECT peso_kg FROM public.body_metrics
            WHERE aluno_id = p_aluno_id
            ORDER BY data_medicao DESC, created_at DESC LIMIT 1
        ),
        'peso_inicial', (
            SELECT valor_inicial FROM public.goals
            WHERE aluno_id = p_aluno_id AND status = 'active' LIMIT 1
        ),
        'peso_meta', (
            SELECT valor_meta FROM public.goals
            WHERE aluno_id = p_aluno_id AND status = 'active' LIMIT 1
        ),
        'ultima_medicao', (
            SELECT data_medicao FROM public.body_metrics
            WHERE aluno_id = p_aluno_id
            ORDER BY data_medicao DESC, created_at DESC LIMIT 1
        ),
        'progresso_kg', (
            SELECT 
                (SELECT valor_inicial FROM goals WHERE aluno_id = p_aluno_id AND status = 'active' LIMIT 1) -
                (SELECT peso_kg FROM body_metrics WHERE aluno_id = p_aluno_id ORDER BY data_medicao DESC LIMIT 1)
        ),
        'objetivo', (
            SELECT jsonb_build_object(
                'tipo', metrica_primaria,
                'meta_kg', valor_meta,
                'prazo', data_fim,
                'motivacao', motivacao_principal
            )
            FROM public.goals
            WHERE aluno_id = p_aluno_id AND status = 'active' LIMIT 1
        )
    ) INTO v_resumo_peso;

    -- CONSTRUIR RESULTADO
    v_resultado_final := v_cabecalho || 
                        '## NUTRIÇÃO' || chr(10) ||
                        jsonb_pretty(v_resumo_nutricao) || chr(10) || chr(10) ||
                        '## TREINO' || chr(10) ||
                        jsonb_pretty(v_resumo_treino) || chr(10) || chr(10) ||
                        '## PESO E OBJETIVO' || chr(10) ||
                        jsonb_pretty(v_resumo_peso) || chr(10) || chr(10) ||
                        '---' || chr(10) ||
                        'Atualizado em: ' || NOW()::TEXT;

    -- ATUALIZAR
    UPDATE public.dynamic_prompts
    SET conquistas_recentes_json = v_resultado_final, updated_at = NOW()
    WHERE aluno_id = p_aluno_id;

    IF NOT FOUND THEN
        INSERT INTO public.dynamic_prompts (aluno_id, conquistas_recentes_json)
        VALUES (p_aluno_id, v_resultado_final);
    END IF;

    RETURN v_resultado_final;
END;
$$;


ALTER FUNCTION "public"."atualizar_resumo_completo_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_old_processed_messages"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  DELETE FROM processed_webhook_messages
  WHERE processed_at < NOW() - INTERVAL '7 days';
END;
$$;


ALTER FUNCTION "public"."cleanup_old_processed_messages"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."criar_convite_para_aluno"("p_aluno_id" "uuid", "p_profissional_id" "uuid") RETURNS character varying
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_codigo VARCHAR(20);
    v_role user_role;
    v_prefixo TEXT;
BEGIN
    -- Busca o role do profissional para definir prefixo
    SELECT role INTO v_role FROM alunos WHERE id = p_profissional_id;
    
    -- Define prefixo baseado no role
    v_prefixo := CASE 
        WHEN v_role = 'nutricionista' THEN 'NUTRI'
        WHEN v_role = 'personal' THEN 'FIT'
        WHEN v_role = 'master' THEN 'COACH'
        ELSE 'TEAM'
    END;
    
    -- Gera código único
    v_codigo := gerar_codigo_convite(v_prefixo);
    
    -- Insere convite
    INSERT INTO convites_alunos (aluno_id, profissional_id, codigo)
    VALUES (p_aluno_id, p_profissional_id, v_codigo);
    
    RETURN v_codigo;
END;
$$;


ALTER FUNCTION "public"."criar_convite_para_aluno"("p_aluno_id" "uuid", "p_profissional_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."criar_convite_para_aluno"("p_aluno_id" "uuid", "p_profissional_id" "uuid") IS 'Cria convite automaticamente ao cadastrar novo aluno. Retorna o código gerado.';



CREATE OR REPLACE FUNCTION "public"."cron_rebuild_all_prompts"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name cron_rebuild_all_prompts
 * @description
 * Função mestre para o pg_cron. Itera sobre TODOS os alunos na
 * tabela 'alunos' e dispara a reconstrução completa do prompt
 * para cada um deles.
 */
DECLARE
    v_aluno_record RECORD;
    v_count INTEGER := 0;
BEGIN
    RAISE NOTICE '[CRON Job] Iniciando reconstrução noturna de TODOS os prompts...';
    
    FOR v_aluno_record IN SELECT id FROM public.alunos
    LOOP
        BEGIN
            PERFORM public.rebuild_full_prompt_for_aluno(v_aluno_record.id);
            v_count := v_count + 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[CRON Job] Falha ao processar Aluno ID: %. Erro: %', v_aluno_record.id, SQLERRM;
        END;
    END LOOP;
    
    RAISE NOTICE '[CRON Job] Reconstrução noturna concluída. Total de alunos processados: %', v_count;
    RETURN 'Concluído: ' || v_count || ' alunos processados.';
END;
$$;


ALTER FUNCTION "public"."cron_rebuild_all_prompts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deletar_usuario_completo"("p_auth_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_aluno_id UUID;
    v_email TEXT;
BEGIN
    -- 1. Verificar se o usuário existe na tabela 'public.alunos' e pegar o ID interno
    SELECT id, email INTO v_aluno_id, v_email
    FROM public.alunos
    WHERE auth_user_id = p_auth_user_id;

    IF v_aluno_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Usuário não encontrado na tabela de alunos (pode já ter sido deletado ou ID incorreto).'
        );
    END IF;

    -- 2. Deletar dados das tabelas relacionadas (Ordem importa por causa das FKs)
    -- Nota: Se suas FKs tiverem 'ON DELETE CASCADE', deletar o aluno já faria isso.
    -- Mas é mais seguro e explícito deletar manualmente ou confiar no CASCADE se configurado.
    
    -- Vamos assumir que as FKs estão configuradas com ON DELETE CASCADE na tabela alunos.
    -- Se sim, deletar de 'public.alunos' vai limpar tudo.
    -- Se não, precisaríamos deletar manualmente de cada tabela:
    -- DELETE FROM public.daily_consumption_history WHERE aluno_id = v_aluno_id;
    -- DELETE FROM public.daily_workout_logs WHERE aluno_id = v_aluno_id;
    -- ... etc.

    -- Vou tentar deletar o aluno diretamente. Se as FKs estiverem corretas, o resto vai junto.
    DELETE FROM public.alunos WHERE id = v_aluno_id;

    -- 3. (Opcional e Avançado) Deletar o usuário da tabela 'auth.users'
    -- Isso remove o login do Supabase Auth.
    -- CUIDADO: Requer permissões especiais que funções PL/pgSQL normais podem não ter por padrão.
    -- Geralmente, deletar de 'public.alunos' é o suficiente para a aplicação, 
    -- e o usuário fica "orfão" no Auth ou você usa a API de Admin do Supabase (JS/Python) para deletar do Auth.
    
    -- Se você quiser deletar do Auth via SQL, precisa de permissão. 
    -- O Supabase geralmente não recomenda fazer isso via RPC por segurança, 
    -- mas sim via client library (supabase.auth.admin.deleteUser).
    
    -- Por isso, vamos focar em limpar os DADOS do usuário.
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Dados do aluno deletados com sucesso.',
        'aluno_id', v_aluno_id,
        'email_removido', v_email,
        'nota', 'O login em auth.users não foi removido por esta função (faça via Painel ou API Admin).'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro ao deletar usuário: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."deletar_usuario_completo"("p_auth_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."desativar_vinculo_profissional"("p_vinculo_id" "uuid", "p_motivo" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    UPDATE aluno_profissional
    SET 
        is_active = false,
        data_fim = CURRENT_DATE,
        observacoes = COALESCE(observacoes || E'\n', '') || 
                      'Desativado em ' || CURRENT_DATE::TEXT || 
                      CASE WHEN p_motivo IS NOT NULL 
                           THEN ': ' || p_motivo 
                           ELSE '' 
                      END,
        updated_at = NOW()
    WHERE id = p_vinculo_id
      AND is_active = true;
END;
$$;


ALTER FUNCTION "public"."desativar_vinculo_profissional"("p_vinculo_id" "uuid", "p_motivo" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."desativar_vinculo_profissional"("p_vinculo_id" "uuid", "p_motivo" "text") IS 'Desativa um vínculo aluno-profissional, registrando data_fim e motivo';



CREATE OR REPLACE FUNCTION "public"."enviar_mensagem_ativacao_whatsapp"("p_whatsapp" "text", "p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_api_key text;
    v_mensagem_instrucao text;
    v_mensagem_codigo text;
    v_primeiro_nome text;
BEGIN
    -- 1. Busca a API Key
    SELECT valor INTO v_api_key FROM public.config_sistema WHERE chave = 'wame_api_key';

    IF v_api_key IS NULL THEN
        RAISE WARNING 'WAME_API_KEY não configurada. Mensagem de ativação não enviada.';
        RETURN;
    END IF;

    -- 2. Busca nome
    SELECT split_part(nome_completo, ' ', 1) INTO v_primeiro_nome 
    FROM public.alunos WHERE id = p_aluno_id;

    -- 3. Monta a MENSAGEM 1 (Instruções)
    v_mensagem_instrucao := format(
        'Olá, %s! 👋 Aqui é da ZapNutri.' || E'\n\n' ||
        'Seu plano de treino e dieta já está pronto! 🚀' || E'\n\n' ||
        'Para ativar sua assistente de IA, por favor:' || E'\n' ||
        '1. Adicione este número aos seus contatos.' || E'\n' ||
        '2. Copie o código abaixo e nos envie como resposta:' || E'\n\n' ||
        'Código:',
        COALESCE(v_primeiro_nome, 'Aluno')
    );

    -- 4. Monta a MENSAGEM 2 (Apenas o Código)
    v_mensagem_codigo := p_aluno_id::text;

    -- 5. Envia MENSAGEM 1
    PERFORM net.http_post(
        url := 'https://us.api-wa.me/' || v_api_key || '/message/text',
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := jsonb_build_object(
            'to', p_whatsapp,
            'text', v_mensagem_instrucao
        )
    );

    -- 6. Envia MENSAGEM 2 (Código Solto)
    PERFORM net.http_post(
        url := 'https://us.api-wa.me/' || v_api_key || '/message/text',
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := jsonb_build_object(
            'to', p_whatsapp,
            'text', v_mensagem_codigo
        )
    );
END;
$$;


ALTER FUNCTION "public"."enviar_mensagem_ativacao_whatsapp"("p_whatsapp" "text", "p_aluno_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_aluno_id uuid;
    v_onboarding_id uuid;
    v_whatsapp_novo text;
    v_tem_dieta boolean;
    v_tem_treino boolean;
BEGIN
    RAISE NOTICE '--- INICIANDO FINALIZAÇÃO. ID RECEBIDO: % ---', p_entrada_id;

    -- 1. DESCOBERTA DE ID: Tenta achar o aluno através do ID do Onboarding
    SELECT aluno_id, id, whatsapp_aluno 
    INTO v_aluno_id, v_onboarding_id, v_whatsapp_novo
    FROM public.onboarding_pendente
    WHERE id = p_entrada_id;

    -- Se não achou pelo ID do registro, assume que o ID passado JÁ É o do aluno
    IF v_aluno_id IS NULL THEN
        RAISE NOTICE 'ID passado não é de um onboarding. Assumindo que é ID de Aluno...';
        v_aluno_id := p_entrada_id;
        
        -- Busca o onboarding usando o ID do aluno
        SELECT id, whatsapp_aluno 
        INTO v_onboarding_id, v_whatsapp_novo
        FROM public.onboarding_pendente
        WHERE aluno_id = v_aluno_id;
    ELSE
        RAISE NOTICE 'ID de Onboarding reconhecido. Aluno vinculado: %', v_aluno_id;
    END IF;

    -- Verificação de segurança: Se ainda assim não achamos o registro de onboarding
    IF v_onboarding_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Erro: Nenhum registro de onboarding pendente encontrado para este ID.'
        );
    END IF;

    -- 2. VALIDAR DIETA (Agora usando o v_aluno_id CORRETO)
    SELECT EXISTS (
        SELECT 1 FROM public.diet_plans WHERE aluno_id = v_aluno_id
    ) INTO v_tem_dieta;

    IF NOT v_tem_dieta THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Erro: Aluno não possui Plano Alimentar cadastrado.'
        );
    END IF;

    -- 3. VALIDAR TREINO (Agora usando o v_aluno_id CORRETO)
    SELECT EXISTS (
        SELECT 1 FROM public.workout_programs WHERE aluno_id = v_aluno_id
    ) INTO v_tem_treino;

    IF NOT v_tem_treino THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Erro: Aluno não possui Programa de Treino cadastrado.'
        );
    END IF;

    -- 4. ATUALIZAR WHATSAPP
    IF v_whatsapp_novo IS NULL OR v_whatsapp_novo = '' THEN
         RETURN jsonb_build_object(
            'success', false, 
            'message', 'Erro: WhatsApp do aluno está vazio no registro de onboarding.'
        );
    END IF;

    UPDATE public.alunos
    SET whatsapp = v_whatsapp_novo,
        updated_at = NOW()
    WHERE id = v_aluno_id;

    -- 5. NOTIFICAÇÃO
    PERFORM public.enviar_mensagem_ativacao_whatsapp(v_whatsapp_novo, v_aluno_id);

    -- 6. LIMPEZA
    DELETE FROM public.onboarding_pendente
    WHERE id = v_onboarding_id;

    -- Retorno de Sucesso
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Onboarding finalizado com sucesso! Mensagem enviada.',
        'aluno_id', v_aluno_id,
        'whatsapp_vinculado', v_whatsapp_novo
    );

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Erro Crítico: %', SQLERRM;
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro interno: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid", "p_profissional_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_aluno_id uuid;
    v_onboarding_id uuid;
    v_whatsapp_novo text;
    v_tem_dieta boolean;
    v_tem_treino boolean;
    
    -- Variáveis para tratamento do telefone
    v_telefone_sem_pais text;
    v_ddd text;
    v_numero_final text;
BEGIN
    RAISE NOTICE '--- INICIANDO FINALIZAÇÃO. ID RECEBIDO: % | PROFISSIONAL: % ---', p_entrada_id, p_profissional_id;

    -- 1. DESCOBERTA DE ID: Tenta achar o aluno através do ID do Onboarding
    SELECT aluno_id, id, whatsapp_aluno 
    INTO v_aluno_id, v_onboarding_id, v_whatsapp_novo
    FROM public.onboarding_pendente
    WHERE id = p_entrada_id;

    -- Se não achou pelo ID do registro, assume que o ID passado JÁ É o do aluno
    IF v_aluno_id IS NULL THEN
        RAISE NOTICE 'ID passado não é de um onboarding. Assumindo que é ID de Aluno...';
        v_aluno_id := p_entrada_id;
        
        -- Busca o onboarding usando o ID do aluno
        SELECT id, whatsapp_aluno 
        INTO v_onboarding_id, v_whatsapp_novo
        FROM public.onboarding_pendente
        WHERE aluno_id = v_aluno_id;
    ELSE
        RAISE NOTICE 'ID de Onboarding reconhecido. Aluno vinculado: %', v_aluno_id;
    END IF;

    -- Verificação de segurança
    IF v_onboarding_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Erro: Nenhum registro de onboarding pendente encontrado para este ID.'
        );
    END IF;

    -- 2. VALIDAR DIETA
    SELECT EXISTS (
        SELECT 1 FROM public.diet_plans WHERE aluno_id = v_aluno_id
    ) INTO v_tem_dieta;

    IF NOT v_tem_dieta THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Erro: Aluno não possui Plano Alimentar cadastrado.'
        );
    END IF;

    -- 3. VALIDAR TREINO
    SELECT EXISTS (
        SELECT 1 FROM public.workout_programs WHERE aluno_id = v_aluno_id
    ) INTO v_tem_treino;

    IF NOT v_tem_treino THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Erro: Aluno não possui Programa de Treino cadastrado.'
        );
    END IF;

    -- 4. TRATAMENTO E ATUALIZAÇÃO DO TELEFONE
    IF v_whatsapp_novo IS NULL OR v_whatsapp_novo = '' THEN
         RETURN jsonb_build_object(
            'success', false, 
            'message', 'Erro: WhatsApp do aluno está vazio no registro de onboarding.'
        );
    END IF;

    -- Lógica de extração: 554892019922 -> DDD: 48, Num: 92019922
    -- Remove os 2 primeiros caracteres (código do país 55)
    v_telefone_sem_pais := substring(v_whatsapp_novo from 3);
    
    -- Pega o DDD (próximos 2 caracteres)
    v_ddd := substring(v_telefone_sem_pais from 1 for 2);
    
    -- Pega o Número (o restante da string)
    v_numero_final := substring(v_telefone_sem_pais from 3);

    -- Atualiza tabela ALUNOS com DDD e Número separados
    -- Nota: Mantivemos a atualização do campo 'whatsapp' completo também para garantir compatibilidade com o resto do sistema
    UPDATE public.alunos
    SET 
        whatsapp = v_whatsapp_novo,
        ddd = v_ddd,
        numero_telefone = v_numero_final,
        updated_at = NOW()
    WHERE id = v_aluno_id;

    -- 5. ATUALIZAÇÃO DO ONBOARDING (Sem deletar)
    -- Registra quem aprovou e muda o status
    UPDATE public.onboarding_pendente
    SET 
        status = 'aprovado',
        profissional_responsavel_id = p_profissional_id,
        aprovado_por_id = p_profissional_id,
        data_aprovacao = NOW(),
        updated_at = NOW()
    WHERE id = v_onboarding_id;

    -- 6. NOTIFICAÇÃO
    PERFORM public.enviar_mensagem_ativacao_whatsapp(v_whatsapp_novo, v_aluno_id);

    -- Retorno de Sucesso
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Onboarding finalizado com sucesso! Mensagem enviada e dados atualizados.',
        'aluno_id', v_aluno_id,
        'whatsapp_vinculado', v_whatsapp_novo,
        'ddd', v_ddd,
        'numero', v_numero_final
    );

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Erro Crítico: %', SQLERRM;
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro interno: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid", "p_profissional_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gerar_codigo_convite"("p_tipo_profissional" "text" DEFAULT 'NUTRI'::"text") RETURNS character varying
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_codigo VARCHAR(20);
    v_existe BOOLEAN;
BEGIN
    LOOP
        -- Gera código: NUTRI-A7B9C (tipo + 5 caracteres alfanuméricos)
        v_codigo := p_tipo_profissional || '-' || 
                    UPPER(SUBSTRING(MD5(RANDOM()::TEXT || CLOCK_TIMESTAMP()::TEXT) FROM 1 FOR 5));
        
        -- Verifica se já existe
        SELECT EXISTS(SELECT 1 FROM convites_alunos WHERE codigo = v_codigo) INTO v_existe;
        
        -- Se não existe, retorna
        IF NOT v_existe THEN
            RETURN v_codigo;
        END IF;
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."gerar_codigo_convite"("p_tipo_profissional" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."gerar_codigo_convite"("p_tipo_profissional" "text") IS 'Gera código único para convite. Exemplo: NUTRI-A7B9C, FIT-X3Y8Z';



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



CREATE OR REPLACE FUNCTION "public"."get_aluno_chart_data"("p_aluno_id" "uuid") RETURNS json
    LANGUAGE "sql" STABLE
    AS $$
  -- Agrega todos os resultados em um único array JSON
  SELECT json_agg(t) 
  FROM (
    
    -- Início da subconsulta
    SELECT
      -- ==================================================
      -- AQUI ESTÁ A ÚNICA ALTERAÇÃO
      -- ==================================================
      -- Converte a data para um timestamp completo (ISO 8601)
      -- Ex: "2025-11-07T00:00:00+00:00"
      data_medicao::timestamptz AS "data",
      -- ==================================================
      
      peso_kg AS "peso",
      
      -- Lógica do delta (da versão anterior)
      FIRST_VALUE(peso_kg) OVER (
          ORDER BY data_medicao ASC, created_at ASC
      ) AS "peso_inicial",
      
      ROUND(
        peso_kg - FIRST_VALUE(peso_kg) OVER (ORDER BY data_medicao ASC, created_at ASC),
        2
      ) AS "delta_peso_total",
    
      -- Outros dados
      percentual_gordura AS "gordura",
      circunferencia_peito_cm AS "peito",
      circunferencia_cintura_cm AS "cintura",
      circunferencia_quadril_cm AS "quadril",
      (medidas_json ->> 'coxa_dir')::numeric AS "coxa_direita",
      (medidas_json ->> 'coxa_esq')::numeric AS "coxa_esquerda",
      (medidas_json ->> 'panturrilha_dir')::numeric AS "panturrilha_direita",
      (medidas_json ->> 'panturrilha_esq')::numeric AS "panturrilha_esquerda",
      (medidas_json ->> 'braco_dir')::numeric AS "braco_direito",
      (medidas_json ->> 'braco_esq')::numeric AS "braco_esquerdo"
      
    FROM
      public.body_metrics
    WHERE
      aluno_id = p_aluno_id
      
    -- Ordenação final
    ORDER BY
      data_medicao ASC
  
  ) t; -- Fim da subconsulta
$$;


ALTER FUNCTION "public"."get_aluno_chart_data"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_aluno_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT id FROM public.alunos 
  WHERE auth_user_id = auth.uid()
  LIMIT 1;
$$;


ALTER FUNCTION "public"."get_current_aluno_id"() OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."get_exercicios_template_json"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
/**
 * @name get_exercicios_template_json
 * @description
 * Retorna um único array JSONB contendo *todos* os exercícios
 * da tabela 'exercicios_template', formatados como objetos JSON
 * (incluindo id, nome e grupo muscular).
 *
 * @returns {jsonb} Ex: [{"id": 1, "nome_exercicio": "Supino...", "grupo_muscular": "Peito"}, ...]
 */
  SELECT jsonb_agg(
    jsonb_build_object(
        'id', id,
        'nome_exercicio', nome_exercicio,
        'grupo_muscular', grupo_muscular
    ) ORDER BY grupo_muscular, nome_exercicio -- Ordena o array para consistência
  )
  FROM public.exercicios_template;
$$;


ALTER FUNCTION "public"."get_exercicios_template_json"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_food_items_template"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  -- 1. Agrega o resultado final em um único array JSON
  SELECT jsonb_agg(categorias)
  FROM (
    -- 2. Subconsulta: Agrupa os itens por categoria
    SELECT
      categoria,
      -- 3. Cria um array JSON para os itens de cada categoria
      json_agg(
        json_build_object(
          'id', id,
          'nome', nome
        ) ORDER BY nome ASC -- Ordena os alimentos em ordem alfabética
      ) AS items
    FROM
      public.food_items
    GROUP BY
      categoria
    ORDER BY
      -- 4. Define uma ordem manual para as categorias aparecerem no frontend
      CASE categoria
        WHEN 'Proteínas' THEN 1
        WHEN 'Carboidratos' THEN 2
        WHEN 'Gorduras, Nozes e Sementes' THEN 3
        WHEN 'Laticínios' THEN 4
        WHEN 'Frutas' THEN 5
        WHEN 'Vegetais e Legumes' THEN 6
        ELSE 7
      END
  ) AS categorias; -- Alias da subconsulta
$$;


ALTER FUNCTION "public"."get_food_items_template"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_food_items_template"() IS 'Retorna um array JSONB com todos os food_items agrupados por categoria.';



CREATE OR REPLACE FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
/**
 * @name get_full_workout_program_json
 * @version 4.0.2
 * @description
 * Retorna o plano de treino semanal completo como um objeto JSON.
 *
 * @changelog
 * v4.0.2:
 * - CORREÇÃO CRÍTICA: Ajustado o mapeamento de dias da semana
 * para o padrão 1-7 (Domingo=1, Sábado=7) conforme
 * especificado pelo usuário, em vez do padrão ISO 0-6.
 * - O filtro foi atualizado para 'pw.dia_da_semana BETWEEN 1 AND 7'.
 * - O CASE statement foi atualizado para o mapeamento 1-7.
 * - Isso corrige o erro "field name must not be null".
 */
DECLARE
    v_workouts_json JSONB;
    v_default_week JSONB := '{
      "domingo": [],
      "segunda": [],
      "terca": [],
      "quarta": [],
      "quinta": [],
      "sexta": [],
      "sabado": []
    }';
BEGIN
    -- 1. Agrega os treinos, filtrando pelo padrão 1-7
    WITH workouts_by_day AS (
      SELECT
        pw.dia_da_semana, -- (Agora 1-7)
        jsonb_agg(
          jsonb_build_object(
            'nome_treino', pw.nome_treino,
            'workout_id', pw.id,
            'exercicios', (
              SELECT jsonb_agg(
                jsonb_build_object(
                  'id', we.id,
                  'ordem', we.ordem,
                  'nome', we.nome_exercicio,
                  'series', we.series,
                  'repeticoes', we.repeticoes,
                  'carga_atual_kg', we.carga_kg,
                  'descanso_seg', we.descanso_segundos,
                  'grupo_muscular', we.grupo_muscular,
                  'exercicio_template_id', we.exercicio_template_id
                ) ORDER BY we.ordem
              )
              FROM public.workout_exercises AS we
              WHERE we.workout_id = pw.id
            )
          ) ORDER BY pw.id
        ) AS workouts_do_dia
      FROM public.program_workouts AS pw
      WHERE 
        pw.program_id = p_program_id
        AND pw.dia_da_semana BETWEEN 1 AND 7 -- <<-- CORREÇÃO AQUI (1-7)
      GROUP BY pw.dia_da_semana
    )
    -- 2. Constrói o JSON final usando o mapeamento 1-7
    SELECT jsonb_object_agg(
        CASE wbd.dia_da_semana
          WHEN 1 THEN 'domingo'  -- <<-- CORREÇÃO AQUI
          WHEN 2 THEN 'segunda'  -- <<-- CORREÇÃO AQUI
          WHEN 3 THEN 'terca'    -- <<-- CORREÇÃO AQUI
          WHEN 4 THEN 'quarta'   -- <<-- CORREÇÃO AQUI
          WHEN 5 THEN 'quinta'   -- <<-- CORREÇÃO AQUI
          WHEN 6 THEN 'sexta'    -- <<-- CORREÇÃO AQUI
          WHEN 7 THEN 'sabado'   -- <<-- CORREÇÃO AQUI
        END,
        wbd.workouts_do_dia
    )
    INTO v_workouts_json
    FROM workouts_by_day AS wbd;
    
    -- 3. Mescla o molde com os treinos (lógica inalterada)
    RETURN v_default_week || COALESCE(v_workouts_json, '{}'::jsonb);
END;
$$;


ALTER FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") IS 'Função auxiliar que busca TODOS os treinos e exercícios de um programa e os formata em um único objeto JSON representando a semana completa.';



CREATE OR REPLACE FUNCTION "public"."get_resumo_treino_para_coach"("p_aluno_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_resultado JSONB;
BEGIN
    SELECT jsonb_build_object(
        'semana_atual', (
            SELECT jsonb_build_object(
                'periodo', semana_inicio || ' a ' || semana_fim,
                'aderencia', percentual_aderencia || '%',
                'treinos_realizados', total_treinos_realizados,
                'treinos_planejados', total_treinos_planejados,
                'dias_completos', dias_completos,
                'status', CASE 
                    WHEN percentual_aderencia >= 90 THEN 'excelente'
                    WHEN percentual_aderencia >= 70 THEN 'bom'
                    WHEN percentual_aderencia >= 50 THEN 'regular'
                    ELSE 'baixo'
                END
            )
            FROM public.vw_treino_resumo_semanal
            WHERE aluno_id = p_aluno_id
              AND semana_inicio = DATE_TRUNC('week', CURRENT_DATE)::DATE
        ),
        'semana_passada', (
            SELECT jsonb_build_object(
                'periodo', semana_inicio || ' a ' || semana_fim,
                'aderencia', percentual_aderencia || '%',
                'treinos_realizados', total_treinos_realizados,
                'comparacao_com_atual', 
                    (SELECT total_treinos_realizados FROM vw_treino_resumo_semanal 
                     WHERE aluno_id = p_aluno_id AND semana_inicio = DATE_TRUNC('week', CURRENT_DATE)::DATE) 
                    - total_treinos_realizados
            )
            FROM public.vw_treino_resumo_semanal
            WHERE aluno_id = p_aluno_id
              AND semana_inicio = DATE_TRUNC('week', CURRENT_DATE - INTERVAL '1 week')::DATE
        ),
        'mes_passado', (
            SELECT jsonb_build_object(
                'periodo', TO_CHAR(mes_inicio, 'Month/YYYY'),
                'aderencia', percentual_aderencia || '%',
                'treinos_realizados', total_treinos_realizados,
                'frequencia_semanal', media_treinos_semana,
                'dias_completos', dias_completos,
                'dias_faltou', dias_faltou
            )
            FROM public.vw_treino_resumo_mensal
            WHERE aluno_id = p_aluno_id
              AND mes_inicio = DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE
        ),
        'historico_recente', (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'data', data_treino,
                    'atividades', atividades_realizadas,
                    'status', status_dia
                ) ORDER BY data_treino DESC
            )
            FROM public.vw_treino_resumo_diario
            WHERE aluno_id = p_aluno_id
              AND data_treino >= CURRENT_DATE - INTERVAL '7 days'
        )
    ) INTO v_resultado;
    
    RETURN v_resultado;
END;
$$;


ALTER FUNCTION "public"."get_resumo_treino_para_coach"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_resumo_treino_para_coach"("p_aluno_id" "uuid") IS 'Retorna resumo completo de treino formatado para alimentar a IA Coach: semana atual, semana passada, mês passado e histórico recente dos últimos 7 dias.';



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



CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_whatsapp VARCHAR(20);
  v_nome VARCHAR(255);
  v_aluno_id UUID;
BEGIN
  -- Extrai dados do metadata
  v_whatsapp := COALESCE(
    NEW.phone, 
    NEW.raw_user_meta_data->>'phone',
    NEW.raw_user_meta_data->>'whatsapp'
  );
  
  v_nome := COALESCE(
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'name',
    split_part(NEW.email, '@', 1)
  );
  
  -- Tenta encontrar aluno existente pelo WhatsApp
  IF v_whatsapp IS NOT NULL THEN
    -- Busca o ID do aluno primeiro
    SELECT id INTO v_aluno_id
    FROM public.alunos
    WHERE whatsapp = v_whatsapp 
      AND auth_user_id IS NULL
    LIMIT 1;
    
    -- Se encontrou, atualiza
    IF v_aluno_id IS NOT NULL THEN
      UPDATE public.alunos
      SET 
        auth_user_id = NEW.id,
        email = COALESCE(email, NEW.email),
        updated_at = NOW()
      WHERE id = v_aluno_id;
      
      RAISE NOTICE 'Aluno existente vinculado ao auth.user: %', NEW.id;
      RETURN NEW;
    END IF;
  END IF;
  
  -- Se não encontrou, cria novo aluno
  INSERT INTO public.alunos (
    auth_user_id,
    nome_completo,
    whatsapp,
    email,
    subscription_status,
    created_at,
    updated_at
  ) VALUES (
    NEW.id,
    v_nome,
    COALESCE(v_whatsapp, ''),
    NEW.email,
    'trial',
    NOW(),
    NOW()
  );
  
  RAISE NOTICE 'Novo aluno criado para auth.user: %', NEW.id;
  RETURN NEW;
  
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Erro ao criar aluno: %', SQLERRM;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."iniciar_novo_plano_de_treino"("p_aluno_id" "uuid", "p_nome_programa" "text", "p_objetivo" "text", "p_frequencia" integer, "p_programas_json" "jsonb") RETURNS TABLE("id" "uuid", "dia_da_semana" smallint, "nome_treino" character varying)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_program_id UUID;
BEGIN
  -- Desativar planos anteriores
  UPDATE public.workout_programs
  SET is_active = false
  WHERE aluno_id = p_aluno_id;

  -- Criar novo programa
  INSERT INTO public.workout_programs (
    aluno_id,
    nome_programa,
    objetivo,
    frequencia_semanal,
    is_active,
    data_inicio
  )
  VALUES (
    p_aluno_id,
    p_nome_programa,
    p_objetivo,
    p_frequencia,
    true,
    CURRENT_DATE
  )
  RETURNING workout_programs.id INTO v_program_id;

  -- Criar treinos da semana
  INSERT INTO public.program_workouts (
    program_id,
    nome_treino,
    dia_da_semana
  )
  SELECT
    v_program_id,
    (rec ->> 'nome_programa')::TEXT,
    (rec ->> 'dia_da_semana')::SMALLINT
  FROM jsonb_array_elements(p_programas_json) AS rec;

  -- Retornar apenas program_workouts (SEM workout_programs.id)
  RETURN QUERY
  SELECT 
    pw.id,
    pw.dia_da_semana,
    pw.nome_treino
  FROM public.program_workouts pw
  WHERE pw.program_id = v_program_id
  ORDER BY pw.dia_da_semana;

END;
$$;


ALTER FUNCTION "public"."iniciar_novo_plano_de_treino"("p_aluno_id" "uuid", "p_nome_programa" "text", "p_objetivo" "text", "p_frequencia" integer, "p_programas_json" "jsonb") OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."limpar_dados_aluno"("p_aluno_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_rows_deleted int;
    v_total_deleted int := 0;
BEGIN
    -- 1. Limpar Cache de IA (Contexto)
    DELETE FROM public.dynamic_prompts WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 2. Limpar Dados de Saúde e Rotina
    DELETE FROM public.saude_e_rotina WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 3. Limpar Preferências Alimentares
    DELETE FROM public.preferencias_alimentares WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 4. Limpar Preferências de Treino
    DELETE FROM public.preferencias_treino WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 5. Limpar Métricas Corporais (Peso/Medidas)
    DELETE FROM public.body_metrics WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 6. Limpar Objetivos/Metas
    -- Nota: Se houver conquistas (achievements) ligadas a meta, o vínculo ficará NULL automaticamente.
    DELETE FROM public.goals WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 7. Limpar Status de Onboarding
    DELETE FROM public.onboarding_pendente WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 8. Limpar Planos de Dieta
    DELETE FROM public.diet_plans WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    -- 9. Remover Vínculo com Profissional
    DELETE FROM public.aluno_profissional WHERE aluno_id = p_aluno_id;
    GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_rows_deleted;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Limpeza concluída para as tabelas solicitadas.',
        'registros_deletados', v_total_deleted,
        'aluno_id', p_aluno_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro ao limpar dados do aluno: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."limpar_dados_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."marcar_onboarding_concluido"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Atualiza o onboarding_pendente para status 'concluido'
    UPDATE public.onboarding_pendente
    SET 
        status = 'aprovado',
        data_aprovacao = NOW(),
        updated_at = NOW()
    WHERE aluno_id = NEW.id
      AND status IN ('aguardando_analise', 'em_revisao');
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."marcar_onboarding_concluido"() OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."rebuild_full_prompt_for_aluno"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
/**
 * @name rebuild_full_prompt_for_aluno
 * @description
 * Função "wrapper" que executa TODAS as funções de rebuild de
 * JSON para um único aluno e, ao final, chama a função de
 * montagem final do 'prompt_final'.
 */
BEGIN
    RAISE NOTICE '[Rebuild Noturno] Reconstruindo blocos para Aluno ID: %', p_aluno_id;
    
    -- 1. Reconstrói a saúde e rotina
    PERFORM public.rebuild_saude_e_rotina_json(p_aluno_id);
    
    -- 2. Reconstrói o objetivo ativo e progresso
    PERFORM public.rebuild_objetivo_ativo_json(p_aluno_id);
    
    -- 3. Reconstrói o plano alimentar
    PERFORM public.rebuild_plano_alimentar_json(p_aluno_id);
    
    -- 4. Reconstrói o plano de treino (com a nova lógica v4.0.2)
    PERFORM public.rebuild_plano_treino_json(p_aluno_id);
    
    -- 5. Reconstrói as conquistas recentes
    PERFORM public.rebuild_conquistas_recentes_json(p_aluno_id);
    
    -- 6. Chama a função de montagem final (que concatena tudo)
    PERFORM public.atualizar_prompt_final_para_aluno(p_aluno_id);

    RAISE NOTICE '[Rebuild Noturno] Concluído para Aluno ID: %', p_aluno_id;
END;
$$;


ALTER FUNCTION "public"."rebuild_full_prompt_for_aluno"("p_aluno_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_goal_record RECORD;
    v_metric_record RECORD;
    v_progress_value NUMERIC;
    v_total_target_value NUMERIC;
    v_progress_percentage NUMERIC;
    v_json_output JSONB;
BEGIN
    RAISE NOTICE '[Rebuild Objetivo v2.1] Iniciando para o aluno ID: %', p_aluno_id;

    -- 1. Busca a meta ativa do aluno (sem alterações)
    SELECT * INTO v_goal_record
    FROM public.goals
    WHERE aluno_id = p_aluno_id AND status = 'active'
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE WARNING '[Rebuild Objetivo v2.1] Nenhuma meta ativa encontrada para o aluno ID: %', p_aluno_id;
        UPDATE public.dynamic_prompts SET objetivo_ativo_json = NULL WHERE aluno_id = p_aluno_id;
        RETURN;
    END IF;

    -- 2. Busca a última medição de peso do aluno (COM A CORREÇÃO)
    SELECT peso_kg INTO v_metric_record
    FROM public.body_metrics
    WHERE aluno_id = p_aluno_id
    ORDER BY
        data_medicao DESC,  -- Ordena pela data primeiro
        created_at DESC     -- Usa a hora da criação como desempate
    LIMIT 1;

    -- 3. Calcula as métricas de progresso (sem alterações)
    v_progress_value := 0;
    v_progress_percentage := 0;
    
    IF v_metric_record.peso_kg IS NOT NULL AND v_goal_record.valor_inicial IS NOT NULL AND v_goal_record.valor_meta IS NOT NULL THEN
        v_progress_value := v_metric_record.peso_kg - v_goal_record.valor_inicial;
        v_total_target_value := ABS(v_goal_record.valor_inicial - v_goal_record.valor_meta);
        IF v_total_target_value > 0 THEN
            v_progress_percentage := ROUND((ABS(v_progress_value) / v_total_target_value) * 100);
        END IF;
    END IF;

    -- 4. Monta o JSON final (sem alterações)
    v_json_output := jsonb_build_object(
        'titulo', v_goal_record.nome_meta,
        'tipo', v_goal_record.metrica_primaria,
        'motivacao', v_goal_record.motivacao_principal,
        'prazo', v_goal_record.data_fim,
        'progresso', jsonb_build_object(
            'peso_inicial_kg', v_goal_record.valor_inicial,
            'peso_atual_kg', v_metric_record.peso_kg,
            'peso_meta_kg', v_goal_record.valor_meta,
            'progresso_kg', ROUND(v_progress_value * -1, 2),
            'progresso_percentual', v_progress_percentage,
            'dias_decorridos', DATE_PART('day', NOW() - v_goal_record.data_inicio)
        )
    );

    -- 5. Atualiza a coluna (sem alterações)
    UPDATE public.dynamic_prompts
    SET objetivo_ativo_json = v_json_output
    WHERE aluno_id = p_aluno_id;

    RAISE NOTICE '[Rebuild Objetivo v2.1] ✅ JSON de objetivo para o aluno ID % foi atualizado com sucesso.', p_aluno_id;

END;
$$;


ALTER FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rebuild_objetivo_ativo_json"("p_aluno_id" "uuid") IS 'Lê a meta ativa e a última medição para calcular o progresso e atualizar a coluna `objetivo_ativo_json` em `dynamic_prompts`.';



CREATE OR REPLACE FUNCTION "public"."rebuild_plano_alimentar_json"("p_aluno_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
/**
 * @name rebuild_plano_alimentar_json
 * @version 1.1.0
 * @changelog v1.1.0: Corrigido o bug 'INSERT' (falha silenciosa).
 * - Substituído 'UPDATE' por 'INSERT ... ON CONFLICT (aluno_id) DO UPDATE'.
 */
DECLARE
    v_diet_plan_record RECORD;
    v_prefs_record RECORD;
    v_json_output JSONB;
BEGIN
    RAISE NOTICE '[Rebuild Plano Alimentar v1.1] Iniciando para o aluno ID: %', p_aluno_id;

    -- 1. Busca o plano de dieta ativo
    SELECT * INTO v_diet_plan_record
    FROM public.diet_plans
    WHERE aluno_id = p_aluno_id AND is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE WARNING '[Rebuild Plano Alimentar v1.1] Nenhum plano de dieta ativo encontrado para o aluno ID: %', p_aluno_id;
        -- Garante que a linha exista e limpa o JSON
        INSERT INTO public.dynamic_prompts (aluno_id, plano_alimentar_json)
        VALUES (p_aluno_id, NULL)
        ON CONFLICT (aluno_id) DO UPDATE
        SET plano_alimentar_json = NULL, updated_at = NOW();
        RETURN;
    END IF;

    -- 2. Busca as preferências alimentares (pode ser nulo)
    SELECT * INTO v_prefs_record
    FROM public.preferencias_alimentares
    WHERE aluno_id = p_aluno_id;

    -- 3. Monta o JSON final
    v_json_output := jsonb_build_object(
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
    );

    -- 4. Atualiza a coluna (Usando UPSERT)
    INSERT INTO public.dynamic_prompts (aluno_id, plano_alimentar_json)
    VALUES (p_aluno_id, v_json_output)
    ON CONFLICT (aluno_id) DO UPDATE
    SET 
      plano_alimentar_json = v_json_output,
      updated_at = NOW();
      
    RAISE NOTICE '[Rebuild Plano Alimentar v1.1] ✅ JSON de plano alimentar atualizado.';
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
DECLARE
    v_prompt_introducao TEXT;
    v_prompt_persona TEXT;
    v_prompt_finais TEXT;
BEGIN
    RAISE NOTICE '[Master Trigger] Reconstruindo prompt_final para o aluno ID: %', NEW.aluno_id;
    
    -- 1. Busca TODOS os prompts estáticos da config
    SELECT valor INTO v_prompt_introducao FROM public.config_sistema WHERE chave = 'prompt_introducao';
    SELECT valor INTO v_prompt_persona FROM public.config_sistema WHERE chave = 'prompt_base_ia';
    SELECT valor INTO v_prompt_finais FROM public.config_sistema WHERE chave = 'prompt_consideracoes_finais';

    -- 2. Concatena tudo (ORDEM CORRIGIDA)
    NEW.prompt_final := CONCAT(
        COALESCE(v_prompt_introducao, ''), E'\n\n',
        COALESCE(v_prompt_persona, ''),
        E'\n\n---\n\n# CAMADA 2: CONTEXTO DINÂMICO DO ALUNO\n\n',
        '## SAÚDE E ROTINA:', E'\n', COALESCE(NEW.saude_e_rotina_json::text, '{}'), E'\n\n',
        '## OBJETIVO ATIVO E PROGRESSO:', E'\n', COALESCE(NEW.objetivo_ativo_json::text, '{}'), E'\n\n',
        '## PLANO ALIMENTAR E PREFERÊNCIAS:', E'\n', COALESCE(NEW.plano_alimentar_json::text, '{}'), E'\n\n',
        '## PLANO DE TREINO (PROGRAMA SEMANAL):', E'\n', COALESCE(NEW.plano_treino_json::text, '{}'), E'\n\n',
        '## CONQUISTAS RECENTES:', E'\n', COALESCE(NEW.conquistas_recentes_json::text, '[]'), E'\n\n',
        '## INSTRUÇÕES DO NUTRICIONISTA:', E'\n', COALESCE(NEW.instrucoes_nutricionista_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## INSTRUÇÕES DO PERSONAL TRAINER:', E'\n', COALESCE(NEW.instrucoes_personal_text, 'Nenhuma instrução específica no momento.'), E'\n\n',
        '## CONSIDERAÇÕES FINAIS:', E'\n', COALESCE(v_prompt_finais, '') -- <<-- CORRIGIDO: NO FINAL
    );
    
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



CREATE OR REPLACE FUNCTION "public"."refresh_nutricao_views"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RAISE NOTICE '[Refresh Views] Iniciando atualização das views de nutrição...';
    
    -- Atualiza view diária
    REFRESH MATERIALIZED VIEW CONCURRENTLY vw_nutricao_resumo_diario;
    RAISE NOTICE '[Refresh Views] ✅ vw_nutricao_resumo_diario atualizada';
    
    -- Atualiza view semanal
    REFRESH MATERIALIZED VIEW CONCURRENTLY vw_nutricao_resumo_semanal;
    RAISE NOTICE '[Refresh Views] ✅ vw_nutricao_resumo_semanal atualizada';
    
    -- Atualiza view mensal
    REFRESH MATERIALIZED VIEW CONCURRENTLY vw_nutricao_resumo_mensal;
    RAISE NOTICE '[Refresh Views] ✅ vw_nutricao_resumo_mensal atualizada';
    
    RETURN 'Todas as views de nutrição foram atualizadas com sucesso em ' || NOW()::TEXT;
    
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[Refresh Views] ❌ Erro ao atualizar views: %', SQLERRM;
    RETURN 'Erro: ' || SQLERRM;
END;
$$;


ALTER FUNCTION "public"."refresh_nutricao_views"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_execucao_treino"("p_aluno_id" "uuid", "p_nome_treino" "text" DEFAULT NULL::"text", "p_descricao_atividade" "text" DEFAULT NULL::"text", "p_duracao_minutos" integer DEFAULT NULL::integer, "p_observacoes" "text" DEFAULT NULL::"text", "p_data_treino" "date" DEFAULT CURRENT_DATE) RETURNS TABLE("execution_id" "uuid", "program_workout_id" "uuid", "nome_treino" "text", "mensagem" "text")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_program_workout_id UUID;
    v_nome_treino TEXT;
    v_execution_id UUID;
    v_dia_semana INTEGER;
BEGIN
    -- Se nome do treino foi informado, buscar pelo nome
    IF p_nome_treino IS NOT NULL THEN
        SELECT pw.id, pw.nome_treino
        INTO v_program_workout_id, v_nome_treino
        FROM public.program_workouts pw
        JOIN public.workout_programs wp ON pw.program_id = wp.id
        WHERE wp.aluno_id = p_aluno_id
          AND wp.is_active = true
          AND LOWER(pw.nome_treino) LIKE LOWER('%' || p_nome_treino || '%')
        LIMIT 1;

        IF v_program_workout_id IS NULL THEN
            RAISE EXCEPTION 'Treino "%" não encontrado no programa ativo do aluno', p_nome_treino;
        END IF;
    ELSE
        -- Ajustar dia da semana: PostgreSQL retorna 0-6, mas seu sistema usa 1-7
        v_dia_semana := EXTRACT(DOW FROM p_data_treino)::INTEGER + 1;
        
        SELECT pw.id, pw.nome_treino
        INTO v_program_workout_id, v_nome_treino
        FROM public.program_workouts pw
        JOIN public.workout_programs wp ON pw.program_id = wp.id
        WHERE wp.aluno_id = p_aluno_id
          AND wp.is_active = true
          AND pw.dia_da_semana = v_dia_semana
        LIMIT 1;

        IF v_program_workout_id IS NULL THEN
            RAISE EXCEPTION 'Nenhum treino planejado para hoje (dia da semana: %) no programa ativo', v_dia_semana;
        END IF;
    END IF;

    -- Verificar se já existe execução
    SELECT dwe.id INTO v_execution_id
    FROM public.daily_workout_executions dwe
    WHERE dwe.aluno_id = p_aluno_id
      AND dwe.program_workout_id = v_program_workout_id
      AND dwe.data_treino = p_data_treino;

    IF v_execution_id IS NOT NULL THEN
        RAISE EXCEPTION 'Já existe registro de execução do treino "%" para a data %', v_nome_treino, p_data_treino;
    END IF;

    -- Inserir a execução
    INSERT INTO public.daily_workout_executions (
        aluno_id,
        program_workout_id,
        data_treino,
        descricao_atividade,
        duracao_minutos,
        observacoes
    )
    VALUES (
        p_aluno_id,
        v_program_workout_id,
        p_data_treino,
        p_descricao_atividade,
        p_duracao_minutos,
        p_observacoes
    )
    RETURNING id INTO v_execution_id;

    -- Retornar resultado
    RETURN QUERY
    SELECT 
        v_execution_id,
        v_program_workout_id,
        v_nome_treino,
        'Treino "' || v_nome_treino || '" registrado com sucesso para ' || p_data_treino::TEXT AS mensagem;
END;
$$;


ALTER FUNCTION "public"."registrar_execucao_treino"("p_aluno_id" "uuid", "p_nome_treino" "text", "p_descricao_atividade" "text", "p_duracao_minutos" integer, "p_observacoes" "text", "p_data_treino" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."registrar_execucao_treino"("p_aluno_id" "uuid", "p_nome_treino" "text", "p_descricao_atividade" "text", "p_duracao_minutos" integer, "p_observacoes" "text", "p_data_treino" "date") IS 'Registra execução de treino com observações. descricao_atividade para cardio (ex: "Corrida 5km"), observacoes para notas gerais (ex: "aumentei carga").';



CREATE OR REPLACE FUNCTION "public"."rejeitar_onboarding"("p_onboarding_id" "uuid", "p_motivo" "text", "p_rejeitado_por_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_onboarding_record RECORD;
BEGIN
    -- 1. Verificar registro
    SELECT * INTO v_onboarding_record
    FROM public.onboarding_pendente
    WHERE id = p_onboarding_id
      AND status IN ('aguardando_analise', 'em_revisao');

    IF v_onboarding_record IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Onboarding não encontrado ou status inválido para rejeição.'
        );
    END IF;

    -- 2. Atualizar status e adicionar motivo nas observações (concatenando)
    -- Vamos salvar o motivo no campo de observações do tipo do profissional
    -- Como não sabemos se quem rejeitou é nutri ou personal, vamos salvar em ambos ou criar um campo genérico.
    -- Para o MVP, vamos salvar no campo 'observacoes_profissional_personal' como log geral.
    
    UPDATE public.onboarding_pendente
    SET 
        status = 'rejeitado',
        aprovado_por_id = p_rejeitado_por_id, -- Usamos a mesma coluna para rastrear quem agiu
        observacoes_profissional_personal = COALESCE(observacoes_profissional_personal, '') || E'\n[REJEIÇÃO]: ' || p_motivo,
        updated_at = NOW()
    WHERE id = p_onboarding_id;

    -- 3. Retorno
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Onboarding rejeitado.'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro ao rejeitar onboarding: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."rejeitar_onboarding"("p_onboarding_id" "uuid", "p_motivo" "text", "p_rejeitado_por_id" "uuid") OWNER TO "postgres";


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
 * @changelog v1.2: Reduzido tempo de agregação para 5 segundos.
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
        RAISE NOTICE '[Trigger Agendador] Nenhuma agregação pendente para o aluno %. Agendando para daqui a 5 segundos...', NEW.aluno_id;

        -- Constrói o comando a ser executado de forma segura usando format()
        v_command := format('SELECT public.run_aggregation_and_reset_flag(%L)', NEW.aluno_id);
        
        -- Agenda a execução da função principal usando o comando formatado
        PERFORM cron.schedule(
            'aggregate-' || NEW.aluno_id::text, -- Nome do job único
            '5 seconds', -- <<-- ALTERAÇÃO AQUI
            v_command -- A variável com o comando correto
        );

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


CREATE OR REPLACE FUNCTION "public"."submeter_onboarding_aluno"("p_aluno_id" "uuid", "p_dados_form" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_profissional_id UUID;
    v_existe_vinculo BOOLEAN;
    v_status_final TEXT;
    v_mensagem_retorno TEXT;
    
    -- Variáveis para extração de dados (Validação)
    v_peso NUMERIC;
    v_altura NUMERIC;
    v_objetivo TEXT;
BEGIN
    -- 1. VALIDAÇÃO DE CAMPOS OBRIGATÓRIOS (Etapa 4.2)
    -- Extraindo dados do JSON para variáveis locais
    v_peso := (p_dados_form->'biometria'->>'peso')::NUMERIC;
    v_altura := (p_dados_form->'biometria'->>'altura')::NUMERIC;
    v_objetivo := p_dados_form->>'objetivo_principal';

    -- Regras de Negócio
    IF v_peso IS NULL OR v_peso <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Peso inválido ou não informado.');
    END IF;
    
    IF v_altura IS NULL OR v_altura <= 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Altura inválida ou não informada.');
    END IF;

    IF v_objetivo IS NULL OR TRIM(v_objetivo) = '' THEN
        RETURN jsonb_build_object('success', false, 'message', 'Objetivo principal é obrigatório.');
    END IF;

    -- 2. PERSISTÊNCIA DOS DADOS NAS TABELAS DO SISTEMA
    -- (Aqui distribuímos o JSON para as tabelas reais para que a IA ou o Profissional possam ler depois)
    
    -- 2.1 Atualizar Body Metrics (Biometria)
    INSERT INTO public.body_metrics (aluno_id, weight_kg, height_cm, measurement_date)
    VALUES (p_aluno_id, v_peso, v_altura, CURRENT_DATE);

    -- 2.2 Atualizar Goals (Meta)
    -- Desativa metas anteriores
    UPDATE public.goals SET status = 'abandoned' WHERE aluno_id = p_aluno_id AND status = 'active';
    
    INSERT INTO public.goals (aluno_id, nome_meta, status, created_at)
    VALUES (p_aluno_id, v_objetivo, 'active', NOW());

    -- 2.3 Salvar Preferências (Simplificado - salva o JSON cru se a estrutura bater, ou adapta)
    INSERT INTO public.preferencias_alimentares (aluno_id, restricoes_alimentares)
    VALUES (p_aluno_id, ARRAY(SELECT jsonb_array_elements_text(p_dados_form->'alimentacao'->'restricoes')))
    ON CONFLICT (aluno_id) DO UPDATE 
    SET restricoes_alimentares = EXCLUDED.restricoes_alimentares;

    -- 3. VERIFICAÇÃO DE VÍNCULO (O "Gatekeeper")
    SELECT profissional_id INTO v_profissional_id
    FROM public.aluno_profissional
    WHERE aluno_id = p_aluno_id AND is_active = true
    LIMIT 1;

    IF v_profissional_id IS NOT NULL THEN
        -- ====================================================
        -- CENÁRIO B2B2C: ALUNO VINCULADO A PROFISSIONAL
        -- ====================================================
        
        -- Salva na tabela de pendência para o Nutri/Personal ver
        INSERT INTO public.onboarding_pendente (
            aluno_id, 
            profissional_responsavel_id, 
            status, 
            dados_completos
        ) VALUES (
            p_aluno_id,
            v_profissional_id,
            'pendente',
            p_dados_form
        )
        ON CONFLICT (aluno_id) DO UPDATE
        SET 
            status = 'pendente',
            profissional_responsavel_id = v_profissional_id,
            dados_completos = p_dados_form,
            updated_at = NOW();

        v_status_final := 'aguardando_profissional';
        v_mensagem_retorno := 'Cadastro recebido! Seu treinador/nutricionista foi notificado para criar seu plano.';

    ELSE
        -- ====================================================
        -- CENÁRIO B2C: ALUNO INDEPENDENTE
        -- ====================================================
        
        -- Não cria pendência, libera para IA
        v_status_final := 'liberado_ia';
        v_mensagem_retorno := 'Cadastro concluído! Nossa IA está analisando seus dados.';
        
        -- (Opcional) Aqui você poderia disparar a IA imediatamente, 
        -- mas é melhor deixar o frontend chamar 'iniciar-plano-de-treino' após receber este sucesso.
    END IF;

    -- 4. RETORNO FINAL
    RETURN jsonb_build_object(
        'success', true,
        'status', v_status_final,
        'message', v_mensagem_retorno,
        'profissional_id', v_profissional_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro ao processar onboarding: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."submeter_onboarding_aluno"("p_aluno_id" "uuid", "p_dados_form" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_profissional_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_vinculo_resultado JSONB;
    v_whatsapp_prof VARCHAR;
BEGIN
    -- 1. Tentar vincular o Profissional (Se ID foi fornecido)
    IF p_profissional_id IS NOT NULL THEN
        -- Chama a função de vínculo da Etapa 2
        v_vinculo_resultado := public.vincular_aluno_profissional(
            p_aluno_id, 
            p_profissional_id
        );
        
        -- Busca o WhatsApp do profissional para preencher na tabela de notificação
        SELECT whatsapp INTO v_whatsapp_prof
        FROM public.alunos
        WHERE id = p_profissional_id;
    END IF;

    -- 2. Inserir/Atualizar na tabela onboarding_pendente
    -- CORREÇÃO: Usando status 'aguardando_analise' que é válido no seu ENUM
    INSERT INTO public.onboarding_pendente (
        aluno_id,
        profissional_responsavel_id,
        tem_dieta_atual,
        dieta_atual_texto,
        tem_treino_atual,
        treino_atual_texto,
        whatsapp_notificacao,
        status, -- Coluna do tipo ENUM
        notificacao_enviada,
        updated_at
    ) VALUES (
        p_aluno_id,
        p_profissional_id,
        p_tem_dieta_atual,
        p_dieta_atual_texto,
        p_tem_treino_atual,
        p_treino_atual_texto,
        v_whatsapp_prof,
        'aguardando_analise', -- <== VALOR CORRIGIDO AQUI
        false,
        NOW()
    )
    ON CONFLICT (aluno_id) DO UPDATE
    SET 
        profissional_responsavel_id = EXCLUDED.profissional_responsavel_id,
        tem_dieta_atual = EXCLUDED.tem_dieta_atual,
        dieta_atual_texto = EXCLUDED.dieta_atual_texto,
        tem_treino_atual = EXCLUDED.tem_treino_atual,
        treino_atual_texto = EXCLUDED.treino_atual_texto,
        whatsapp_notificacao = EXCLUDED.whatsapp_notificacao,
        status = 'aguardando_analise', -- <== VALOR CORRIGIDO AQUI (Reseta se reenviar)
        updated_at = NOW();

    -- 3. Retorno de Sucesso
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Onboarding registrado com sucesso.',
        'profissional_vinculado', p_profissional_id IS NOT NULL
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro ao salvar onboarding: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_profissional_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_whatsapp" "text", "p_profissional_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_vinculo_resultado JSONB;
    v_whatsapp_prof VARCHAR;
BEGIN
    -- A. Tentar vincular o Profissional (Se ID foi fornecido)
    IF p_profissional_id IS NOT NULL THEN
        v_vinculo_resultado := public.vincular_aluno_profissional(
            p_aluno_id, 
            p_profissional_id
        );
        
        -- Busca Zap do Profissional para notificação
        SELECT whatsapp INTO v_whatsapp_prof
        FROM public.alunos
        WHERE id = p_profissional_id;
    END IF;

    -- B. Inserir/Atualizar com o novo campo whatsapp_aluno
    INSERT INTO public.onboarding_pendente (
        aluno_id,
        profissional_responsavel_id,
        tem_dieta_atual,
        dieta_atual_texto,
        tem_treino_atual,
        treino_atual_texto,
        whatsapp_aluno,      -- <== SALVANDO AQUI
        whatsapp_notificacao, -- Zap do Profissional (para o bot avisar ele)
        status,
        notificacao_enviada,
        updated_at
    ) VALUES (
        p_aluno_id,
        p_profissional_id,
        p_tem_dieta_atual,
        p_dieta_atual_texto,
        p_tem_treino_atual,
        p_treino_atual_texto,
        p_whatsapp,          -- <== VALOR DO PARAMETRO
        v_whatsapp_prof,
        'aguardando_analise',
        false,
        NOW()
    )
    ON CONFLICT (aluno_id) DO UPDATE
    SET 
        profissional_responsavel_id = EXCLUDED.profissional_responsavel_id,
        tem_dieta_atual = EXCLUDED.tem_dieta_atual,
        dieta_atual_texto = EXCLUDED.dieta_atual_texto,
        tem_treino_atual = EXCLUDED.tem_treino_atual,
        treino_atual_texto = EXCLUDED.treino_atual_texto,
        whatsapp_aluno = EXCLUDED.whatsapp_aluno, -- Atualiza se mudar
        whatsapp_notificacao = EXCLUDED.whatsapp_notificacao,
        status = 'aguardando_analise',
        updated_at = NOW();

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Onboarding registrado com sucesso.',
        'whatsapp_salvo', p_whatsapp
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro ao salvar onboarding: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_whatsapp" "text", "p_profissional_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."trigger_convite_ativado"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.status = 'ativado' AND OLD.status = 'pendente' THEN
        -- Atualiza o timestamp do aluno
        UPDATE alunos SET updated_at = NOW() WHERE id = NEW.aluno_id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_convite_ativado"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_onboarding_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_onboarding_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_updated_at_column"() IS 'Função trigger genérica que atualiza automaticamente o campo updated_at para NOW() em qualquer UPDATE.';



CREATE OR REPLACE FUNCTION "public"."validar_profissional_responsavel"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.profissional_responsavel_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM alunos 
            WHERE id = NEW.profissional_responsavel_id 
            AND role IN ('nutricionista', 'personal', 'master', 'dev')
        ) THEN
            RAISE EXCEPTION 'Profissional responsavel deve ter role nutricionista, personal, master ou dev';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validar_profissional_responsavel"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_profissional_role"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_role user_role;
BEGIN
    -- Busca o role do profissional
    SELECT role INTO v_role
    FROM alunos
    WHERE id = NEW.profissional_id;
    
    -- Valida se é um profissional válido
    IF v_role NOT IN ('nutricionista', 'personal', 'master', 'dev') THEN
        RAISE EXCEPTION 'Profissional deve ter role nutricionista, personal, master ou dev. Role atual: %', v_role;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_profissional_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."vincular_aluno_profissional"("p_aluno_id" "uuid", "p_profissional_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_role_profissional public.user_role;
    v_tipo_profissional public.tipo_profissional;
    v_vinculo_id UUID;
BEGIN
    -- 1. Verificar se o Profissional existe e pegar sua Role
    SELECT role INTO v_role_profissional
    FROM public.alunos
    WHERE id = p_profissional_id;

    IF v_role_profissional IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Profissional não encontrado com este ID.'
        );
    END IF;

    -- 2. Definir o tipo de vínculo baseado na Role do profissional
    IF v_role_profissional = 'nutricionista' THEN
        v_tipo_profissional := 'nutricionista';
    ELSIF v_role_profissional = 'personal' THEN
        v_tipo_profissional := 'personal';
    ELSIF v_role_profissional IN ('master', 'dev') THEN
        v_tipo_profissional := 'master'; -- Master atende como ambos
    ELSE
        -- Se for um aluno tentando indicar outro aluno, bloqueamos ou tratamos aqui
        RETURN jsonb_build_object(
            'success', false,
            'message', 'O ID informado não pertence a um profissional de saúde válido.'
        );
    END IF;

    -- 3. Criar o Vínculo (Upsert para evitar erros se clicar duas vezes)
    INSERT INTO public.aluno_profissional (
        aluno_id,
        profissional_id,
        tipo_profissional,
        is_active,
        data_inicio
    ) VALUES (
        p_aluno_id,
        p_profissional_id,
        v_tipo_profissional,
        true,
        CURRENT_DATE
    )
    ON CONFLICT (aluno_id, profissional_id, tipo_profissional) 
    WHERE is_active = true
    DO NOTHING -- Se já está vinculado, não faz nada e retorna sucesso
    RETURNING id INTO v_vinculo_id;

    -- 4. Retorno
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Aluno vinculado ao profissional com sucesso.',
        'profissional_id', p_profissional_id,
        'tipo_vinculo', v_tipo_profissional
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'message', 'Erro interno ao criar vínculo: ' || SQLERRM
    );
END;
$$;


ALTER FUNCTION "public"."vincular_aluno_profissional"("p_aluno_id" "uuid", "p_profissional_id" "uuid") OWNER TO "postgres";

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



CREATE TABLE IF NOT EXISTS "public"."aluno_profissional" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "profissional_id" "uuid" NOT NULL,
    "tipo_profissional" "public"."tipo_profissional" NOT NULL,
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_fim" "date",
    "is_active" boolean DEFAULT true NOT NULL,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chk_aluno_diferente_profissional" CHECK (("aluno_id" <> "profissional_id")),
    CONSTRAINT "chk_data_fim_maior" CHECK ((("data_fim" IS NULL) OR ("data_fim" > "data_inicio")))
);


ALTER TABLE "public"."aluno_profissional" OWNER TO "postgres";


COMMENT ON TABLE "public"."aluno_profissional" IS 'Relacionamento N:N entre alunos e profissionais (nutricionistas/personals). Mantém histórico de vínculos.';



COMMENT ON COLUMN "public"."aluno_profissional"."aluno_id" IS 'ID do aluno sendo atendido';



COMMENT ON COLUMN "public"."aluno_profissional"."profissional_id" IS 'ID do profissional (deve ter role adequada)';



COMMENT ON COLUMN "public"."aluno_profissional"."tipo_profissional" IS 'Especialidade do atendimento: nutricionista ou personal';



COMMENT ON COLUMN "public"."aluno_profissional"."data_inicio" IS 'Data de início do vínculo';



COMMENT ON COLUMN "public"."aluno_profissional"."data_fim" IS 'Data de término do vínculo (NULL = ainda ativo)';



COMMENT ON COLUMN "public"."aluno_profissional"."is_active" IS 'Indica se o vínculo está ativo no momento';



COMMENT ON COLUMN "public"."aluno_profissional"."observacoes" IS 'Observações sobre o vínculo (motivo de término, etc)';



CREATE TABLE IF NOT EXISTS "public"."alunos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome_completo" character varying(255) NOT NULL,
    "whatsapp" character varying(20) DEFAULT ''::character varying,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "subscription_status" character varying(30) DEFAULT 'trial'::character varying,
    "last_interaction_at" timestamp with time zone,
    "agregacao_agendada" boolean DEFAULT false NOT NULL,
    "aguardando_confirmacao" "jsonb",
    "auth_user_id" "uuid",
    "email" character varying(255),
    "avatar_url" "text",
    "is_onboarding_complete" boolean DEFAULT false,
    "role" "public"."user_role" DEFAULT 'aluno'::"public"."user_role" NOT NULL,
    "ddd" "text",
    "numero_telefone" "text"
);


ALTER TABLE "public"."alunos" OWNER TO "postgres";


COMMENT ON TABLE "public"."alunos" IS 'Tabela central de usuários/alunos da plataforma NutriCoach AI';



COMMENT ON COLUMN "public"."alunos"."subscription_status" IS 'Status atual da assinatura do aluno (ex: trial, active, cancelled).';



COMMENT ON COLUMN "public"."alunos"."last_interaction_at" IS 'Timestamp da última mensagem recebida do aluno, para controle de atividade.';



COMMENT ON COLUMN "public"."alunos"."agregacao_agendada" IS 'Flag booleana que indica se já existe um job de agregação de mensagens agendado para este aluno. Controlado por trigger.';



COMMENT ON COLUMN "public"."alunos"."role" IS 'Papel do usuário no sistema. Define permissões e acesso a funcionalidades.';



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
    "registrado_por_profissional_id" "uuid",
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



COMMENT ON COLUMN "public"."body_metrics"."registrado_por_profissional_id" IS 'ID do profissional que registrou esta medição (NULL = auto-registro do aluno)';



CREATE TABLE IF NOT EXISTS "public"."botoes_ativos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "conversation_id" "text" NOT NULL,
    "tool_call_id" "text" NOT NULL,
    "tipo_acao" "text" NOT NULL,
    "argumentos" "jsonb" NOT NULL,
    "edge_function" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."botoes_ativos" OWNER TO "postgres";


COMMENT ON TABLE "public"."botoes_ativos" IS 'Armazena estado de botões de confirmação pendentes. Apenas um botão ativo por aluno. Deletado após confirmação/cancelamento.';



COMMENT ON COLUMN "public"."botoes_ativos"."aluno_id" IS 'ID do aluno (UNIQUE - apenas um botão por aluno)';



COMMENT ON COLUMN "public"."botoes_ativos"."conversation_id" IS 'ID da conversation OpenAI para finalizar o tool call';



COMMENT ON COLUMN "public"."botoes_ativos"."tool_call_id" IS 'ID do tool call OpenAI que está aguardando resposta';



COMMENT ON COLUMN "public"."botoes_ativos"."tipo_acao" IS 'Tipo de ação pendente (ex: registro_refeicao, update_carga)';



COMMENT ON COLUMN "public"."botoes_ativos"."argumentos" IS 'Argumentos originais da tool call armazenados em JSON';



COMMENT ON COLUMN "public"."botoes_ativos"."edge_function" IS 'Nome da Edge Function que processa a confirmação/cancelamento';



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



CREATE TABLE IF NOT EXISTS "public"."convites_alunos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "profissional_id" "uuid" NOT NULL,
    "codigo" character varying(20) NOT NULL,
    "status" character varying(20) DEFAULT 'pendente'::character varying NOT NULL,
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_ativacao" timestamp with time zone,
    "expira_em" timestamp with time zone DEFAULT ("now"() + '7 days'::interval) NOT NULL,
    "whatsapp_ativado" character varying(20),
    "tentativas_uso" integer DEFAULT 0,
    CONSTRAINT "chk_convite_status" CHECK ((("status")::"text" = ANY ((ARRAY['pendente'::character varying, 'ativado'::character varying, 'expirado'::character varying, 'cancelado'::character varying])::"text"[])))
);


ALTER TABLE "public"."convites_alunos" OWNER TO "postgres";


COMMENT ON TABLE "public"."convites_alunos" IS 'Convites para ativação de alunos via WhatsApp. Gerados pelo profissional ao criar o perfil do aluno.';



COMMENT ON COLUMN "public"."convites_alunos"."aluno_id" IS 'ID do aluno que será ativado com este convite';



COMMENT ON COLUMN "public"."convites_alunos"."profissional_id" IS 'ID do profissional que gerou o convite';



COMMENT ON COLUMN "public"."convites_alunos"."codigo" IS 'Código único que o aluno envia no WhatsApp (ex: NUTRI-A7B9C)';



COMMENT ON COLUMN "public"."convites_alunos"."status" IS 'Status: pendente, ativado, expirado, cancelado';



COMMENT ON COLUMN "public"."convites_alunos"."expira_em" IS 'Data de expiração do convite (padrão: 7 dias)';



COMMENT ON COLUMN "public"."convites_alunos"."whatsapp_ativado" IS 'Número de WhatsApp usado na ativação';



COMMENT ON COLUMN "public"."convites_alunos"."tentativas_uso" IS 'Contador de tentativas de uso (anti-spam)';



CREATE TABLE IF NOT EXISTS "public"."daily_consumption_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "data_registro" "date" NOT NULL,
    "consumo_calorias" integer DEFAULT 0 NOT NULL,
    "consumo_proteina" integer DEFAULT 0 NOT NULL,
    "consumo_carboidrato" integer DEFAULT 0 NOT NULL,
    "consumo_gordura" integer DEFAULT 0 NOT NULL,
    "consumo_agua_ml" integer DEFAULT 0 NOT NULL,
    "analise_qualitativa" "text" DEFAULT ''::"text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confirmada" boolean DEFAULT false
);


ALTER TABLE "public"."daily_consumption_history" OWNER TO "postgres";


COMMENT ON TABLE "public"."daily_consumption_history" IS 'Histórico de registros individuais de refeições. Permite múltiplos registros por dia.';



CREATE TABLE IF NOT EXISTS "public"."daily_workout_executions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "data_treino" "date" DEFAULT CURRENT_DATE NOT NULL,
    "program_workout_id" "uuid" NOT NULL,
    "descricao_atividade" "text",
    "duracao_minutos" integer,
    "observacoes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."daily_workout_executions" OWNER TO "postgres";


COMMENT ON TABLE "public"."daily_workout_executions" IS 'Registra a execução diária de treinos (musculação e cardio). Forma simplificada apenas para rastrear aderência - se o aluno fez ou não o treino planejado.';



COMMENT ON COLUMN "public"."daily_workout_executions"."descricao_atividade" IS 'Descrição livre da atividade, especialmente para cardio. Ex: "Corrida 40min", "Bike", "Escada". NULL para treinos de musculação planejados.';



COMMENT ON COLUMN "public"."daily_workout_executions"."duracao_minutos" IS 'Duração em minutos da atividade. Opcional.';



COMMENT ON COLUMN "public"."daily_workout_executions"."observacoes" IS 'Observações sobre a execução do treino (como foi, sensações, ajustes de carga, etc)';



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
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "criado_por_profissional_id" "uuid"
);


ALTER TABLE "public"."diet_plans" OWNER TO "postgres";


COMMENT ON TABLE "public"."diet_plans" IS 'Planos alimentares personalizados e versionados para cada aluno';



COMMENT ON COLUMN "public"."diet_plans"."criado_por_profissional_id" IS 'ID do profissional (nutricionista/master) que criou este plano alimentar';



CREATE TABLE IF NOT EXISTS "public"."dynamic_prompts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "saude_e_rotina_json" "jsonb",
    "objetivo_ativo_json" "jsonb",
    "plano_alimentar_json" "jsonb",
    "plano_treino_json" "jsonb",
    "conquistas_recentes_json" "text",
    "instrucoes_nutricionista_text" "text",
    "instrucoes_personal_text" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "prompt_final" "text",
    "conversation_id" "text",
    "last_response_id" "text"
);


ALTER TABLE "public"."dynamic_prompts" OWNER TO "postgres";


COMMENT ON TABLE "public"."dynamic_prompts" IS 'Tabela central de cache de contexto para a IA. Cada coluna armazena um "bloco" de informações do aluno, que são atualizadas por triggers para montagem eficiente do prompt.';



COMMENT ON COLUMN "public"."dynamic_prompts"."saude_e_rotina_json" IS 'Cache dos dados da tabela `saude_e_rotina`.';



COMMENT ON COLUMN "public"."dynamic_prompts"."objetivo_ativo_json" IS 'Cache do progresso da meta ativa, calculado a partir de `goals` e `body_metrics`.';



COMMENT ON COLUMN "public"."dynamic_prompts"."plano_alimentar_json" IS 'Cache do plano de dieta ativo (`diet_plans`) enriquecido com as preferências (`preferencias_alimentares`).';



COMMENT ON COLUMN "public"."dynamic_prompts"."plano_treino_json" IS 'Cache do programa de treino ativo (tabelas de `workout`) enriquecido com as preferências (`preferencias_treino`).';



COMMENT ON COLUMN "public"."dynamic_prompts"."conquistas_recentes_json" IS 'Cache das últimas conquistas da tabela `achievements`.';



COMMENT ON COLUMN "public"."dynamic_prompts"."instrucoes_nutricionista_text" IS 'Instruções personalizadas do nutricionista para o aluno.';



COMMENT ON COLUMN "public"."dynamic_prompts"."instrucoes_personal_text" IS 'Instruções personalizadas do personal trainer para o aluno.';



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



CREATE TABLE IF NOT EXISTS "public"."exercicios_template" (
    "id" integer NOT NULL,
    "nome_exercicio" "text" NOT NULL,
    "grupo_muscular" "text" NOT NULL,
    CONSTRAINT "chk_grupo_muscular" CHECK (("grupo_muscular" = ANY (ARRAY['Peito'::"text", 'Costas'::"text", 'Perna'::"text", 'Ombro'::"text", 'Braço'::"text", 'Abdômen'::"text", 'Cardio'::"text"])))
);


ALTER TABLE "public"."exercicios_template" OWNER TO "postgres";


COMMENT ON TABLE "public"."exercicios_template" IS 'Tabela mestre (template) de todos os exercícios de academia disponíveis no sistema.';



COMMENT ON COLUMN "public"."exercicios_template"."id" IS 'ID numérico auto-incrementado para fácil referência.';



COMMENT ON COLUMN "public"."exercicios_template"."grupo_muscular" IS 'O grupo muscular primário treinado pelo exercício.';



CREATE SEQUENCE IF NOT EXISTS "public"."exercicios_template_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."exercicios_template_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."exercicios_template_id_seq" OWNED BY "public"."exercicios_template"."id";



CREATE TABLE IF NOT EXISTS "public"."food_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "categoria" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."food_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."food_items" IS 'Tabela mestre (template) de todos os alimentos para seleção de preferências (Gosta/Não Gosta).';



COMMENT ON COLUMN "public"."food_items"."categoria" IS 'Categoria do alimento (ex: Frutas, Legumes, Carnes, Laticínios).';



COMMENT ON COLUMN "public"."food_items"."nome" IS 'Nome do alimento (ex: Maçã, Alface, Peito de Frango).';



CREATE TABLE IF NOT EXISTS "public"."funcoes_ia" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome_funcao" "text" NOT NULL,
    "definicao_openai" "jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "contexto" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "edge_function" "text"
);


ALTER TABLE "public"."funcoes_ia" OWNER TO "postgres";


COMMENT ON TABLE "public"."funcoes_ia" IS 'Armazena as definições de ferramentas (functions) da OpenAI para serem injetadas dinamicamente no orquestrador da IA.';



COMMENT ON COLUMN "public"."funcoes_ia"."nome_funcao" IS 'O nome exato da função (ex: "propor_atualizacao_carga").';



COMMENT ON COLUMN "public"."funcoes_ia"."definicao_openai" IS 'O objeto JSON completo no formato esperado pela API de "tools" da OpenAI.';



COMMENT ON COLUMN "public"."funcoes_ia"."is_active" IS 'Flag para habilitar ou desabilitar o uso desta função pela IA.';



COMMENT ON COLUMN "public"."funcoes_ia"."contexto" IS 'Opcional. Usado para filtrar funções (ex: "nutricao", "treino").';



COMMENT ON COLUMN "public"."funcoes_ia"."edge_function" IS 'Nome da Edge Function (ex: "propor-registro-refeicao") que o orquestrador deve invocar quando esta ferramenta for chamada pela IA.';



CREATE TABLE IF NOT EXISTS "public"."goals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "metrica_primaria" character varying(30) NOT NULL,
    "valor_meta" numeric(5,2),
    "motivacao_principal" "text",
    "data_inicio" "date" DEFAULT CURRENT_DATE NOT NULL,
    "data_fim" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nome_meta" character varying(255),
    "status" character varying(30) DEFAULT 'ativo'::character varying NOT NULL,
    "valor_inicial" numeric,
    "is_cyclical" boolean DEFAULT false NOT NULL,
    "unidade" "text",
    "ciclo_dias" integer,
    "frequencia_no_ciclo" integer,
    "criado_por_profissional_id" "uuid",
    CONSTRAINT "goals_target_peso_kg_check" CHECK ((("valor_meta" > (0)::numeric) AND ("valor_meta" < (300)::numeric)))
);


ALTER TABLE "public"."goals" OWNER TO "postgres";


COMMENT ON TABLE "public"."goals" IS 'Objetivos de fitness e nutrição definidos pelos alunos';



COMMENT ON COLUMN "public"."goals"."nome_meta" IS 'Um nome ou título para a meta (ex: "Projeto Verão -10kg").';



COMMENT ON COLUMN "public"."goals"."status" IS 'O estado atual da meta (ex: ativo, concluido_sucesso, abandonado).';



COMMENT ON COLUMN "public"."goals"."valor_inicial" IS 'O valor da métrica principal (ex: peso) no momento da criação da meta, para cálculo de progresso.';



COMMENT ON COLUMN "public"."goals"."is_cyclical" IS 'Flag que define o tipo de meta: false para alvo numérico (ex: peso), true para frequência (ex: treinar X vezes na semana).';



COMMENT ON COLUMN "public"."goals"."ciclo_dias" IS 'Para metas cíclicas, define a duração do ciclo em dias (ex: 7 para semanal).';



COMMENT ON COLUMN "public"."goals"."frequencia_no_ciclo" IS 'Para metas cíclicas, define o número de ocorrências desejadas dentro do ciclo.';



COMMENT ON COLUMN "public"."goals"."criado_por_profissional_id" IS 'ID do profissional que definiu esta meta para o aluno';



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
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "instrucoes_da_ia" "text",
    "logs_ia" "jsonb",
    "conversation_id" "text",
    "criado_por_profissional_id" "uuid"
);


ALTER TABLE "public"."instrucoes_nutricionista" OWNER TO "postgres";


COMMENT ON TABLE "public"."instrucoes_nutricionista" IS 'Armazena instruções específicas e personalizadas de um nutricionista para o aluno.';



COMMENT ON COLUMN "public"."instrucoes_nutricionista"."instrucoes_texto" IS 'A instrução FINAL, editada e aprovada pelo humano, que será mostrada ao aluno.';



COMMENT ON COLUMN "public"."instrucoes_nutricionista"."instrucoes_da_ia" IS 'Sugestão de instrução gerada pela IA (em texto) para revisão do nutricionista.';



COMMENT ON COLUMN "public"."instrucoes_nutricionista"."logs_ia" IS 'Log de dados brutos (JSON) das análises da IA para auditoria e "legado".';



COMMENT ON COLUMN "public"."instrucoes_nutricionista"."criado_por_profissional_id" IS 'ID do nutricionista que criou estas instruções';



CREATE TABLE IF NOT EXISTS "public"."instrucoes_personal" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "instrucoes_texto" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "instrucoes_da_ia" "text",
    "logs_ia" "jsonb",
    "conversation_id" "text",
    "criado_por_profissional_id" "uuid"
);


ALTER TABLE "public"."instrucoes_personal" OWNER TO "postgres";


COMMENT ON TABLE "public"."instrucoes_personal" IS 'Armazena instruções específicas e personalizadas de um personal trainer para o aluno.';



COMMENT ON COLUMN "public"."instrucoes_personal"."instrucoes_texto" IS 'A instrução FINAL, editada e aprovada pelo humano, que será mostrada ao aluno.';



COMMENT ON COLUMN "public"."instrucoes_personal"."instrucoes_da_ia" IS 'Sugestão de instrução gerada pela IA (em texto) para revisão do personal trainer.';



COMMENT ON COLUMN "public"."instrucoes_personal"."logs_ia" IS 'Log de dados brutos (JSON) das análises da IA para auditoria e "legado".';



COMMENT ON COLUMN "public"."instrucoes_personal"."criado_por_profissional_id" IS 'ID do personal trainer que criou estas instruções';



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



CREATE TABLE IF NOT EXISTS "public"."onboarding_pendente" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aluno_id" "uuid" NOT NULL,
    "profissional_responsavel_id" "uuid",
    "status" "public"."status_onboarding" DEFAULT 'aguardando_analise'::"public"."status_onboarding" NOT NULL,
    "tem_dieta_atual" boolean DEFAULT false NOT NULL,
    "dieta_atual_texto" "text",
    "tem_treino_atual" boolean DEFAULT false NOT NULL,
    "treino_atual_texto" "text",
    "whatsapp_notificacao" character varying(20),
    "notificacao_enviada" boolean DEFAULT false NOT NULL,
    "observacoes_profissional_nutri" "text",
    "observacoes_profissional_personal" "text",
    "data_criacao" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_aprovacao" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "aprovado_por_id" "uuid",
    "whatsapp_aluno" character varying(20),
    CONSTRAINT "chk_aprovacao_completa" CHECK ((("status" <> 'aprovado'::"public"."status_onboarding") OR (("status" = 'aprovado'::"public"."status_onboarding") AND ("data_aprovacao" IS NOT NULL) AND ("aprovado_por_id" IS NOT NULL)))),
    CONSTRAINT "chk_dieta_texto" CHECK ((("tem_dieta_atual" = false) OR (("tem_dieta_atual" = true) AND ("dieta_atual_texto" IS NOT NULL) AND ("length"(TRIM(BOTH FROM "dieta_atual_texto")) > 0)))),
    CONSTRAINT "chk_treino_texto" CHECK ((("tem_treino_atual" = false) OR (("tem_treino_atual" = true) AND ("treino_atual_texto" IS NOT NULL) AND ("length"(TRIM(BOTH FROM "treino_atual_texto")) > 0))))
);


ALTER TABLE "public"."onboarding_pendente" OWNER TO "postgres";


COMMENT ON TABLE "public"."onboarding_pendente" IS 'Fila de aprovação de novos alunos. Armazena alunos que completaram onboarding e aguardam criação de planos personalizados.';



COMMENT ON COLUMN "public"."onboarding_pendente"."aluno_id" IS 'ID do aluno que completou o onboarding';



COMMENT ON COLUMN "public"."onboarding_pendente"."profissional_responsavel_id" IS 'ID do profissional responsável. NULL = será atribuído ao ZapNutri';



COMMENT ON COLUMN "public"."onboarding_pendente"."status" IS 'Status atual do processo de aprovação';



COMMENT ON COLUMN "public"."onboarding_pendente"."tem_dieta_atual" IS 'Aluno informou que já possui uma dieta/plano alimentar';



COMMENT ON COLUMN "public"."onboarding_pendente"."dieta_atual_texto" IS 'Descrição da dieta atual fornecida pelo aluno';



COMMENT ON COLUMN "public"."onboarding_pendente"."tem_treino_atual" IS 'Aluno informou que já possui um plano de treino';



COMMENT ON COLUMN "public"."onboarding_pendente"."treino_atual_texto" IS 'Descrição do treino atual fornecido pelo aluno';



COMMENT ON COLUMN "public"."onboarding_pendente"."whatsapp_notificacao" IS 'WhatsApp do profissional responsável para envio de notificações';



COMMENT ON COLUMN "public"."onboarding_pendente"."observacoes_profissional_nutri" IS 'Observações e orientações do nutricionista sobre o caso';



COMMENT ON COLUMN "public"."onboarding_pendente"."observacoes_profissional_personal" IS 'Observações e orientações do personal trainer sobre o caso';



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
    "metadata" "jsonb",
    "status" "text" DEFAULT 'completed'::"text",
    CONSTRAINT "processed_webhook_messages_status_check" CHECK (("status" = ANY (ARRAY['processing'::"text", 'completed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."processed_webhook_messages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."processed_webhook_messages"."status" IS 'Status do processamento: processing (em andamento), completed (concluído), failed (falhou)';



CREATE TABLE IF NOT EXISTS "public"."program_workouts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "program_id" "uuid" NOT NULL,
    "dia_da_semana" smallint NOT NULL,
    "nome_treino" character varying(255)
);


ALTER TABLE "public"."program_workouts" OWNER TO "postgres";


COMMENT ON TABLE "public"."program_workouts" IS 'Tabela de ligação que define qual treino ocorre em qual dia da semana para um determinado programa.';



CREATE TABLE IF NOT EXISTS "public"."prompts_sistema" (
    "chave" "text" NOT NULL,
    "prompt_base" "text",
    "informacoes" "text",
    "consideracoes_finais" "text",
    "functions_jsonb" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "prompt_final" "text" GENERATED ALWAYS AS (((((COALESCE("prompt_base", ''::"text") || '

'::"text") || COALESCE("informacoes", ''::"text")) || '

'::"text") || COALESCE("consideracoes_finais", ''::"text"))) STORED
);


ALTER TABLE "public"."prompts_sistema" OWNER TO "postgres";


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



CREATE OR REPLACE VIEW "public"."vw_aluno_completo" AS
 SELECT "a"."id",
    "a"."nome_completo",
    "a"."whatsapp",
    "a"."created_at",
    "a"."updated_at",
    "a"."subscription_status",
    "a"."last_interaction_at",
    "a"."agregacao_agendada",
    "a"."aguardando_confirmacao",
    "a"."auth_user_id",
    "a"."email",
    "a"."avatar_url",
    "a"."is_onboarding_complete",
    "u"."email" AS "auth_email",
    "u"."email_confirmed_at",
    "u"."phone" AS "auth_phone",
    "u"."last_sign_in_at"
   FROM ("public"."alunos" "a"
     LEFT JOIN "auth"."users" "u" ON (("a"."auth_user_id" = "u"."id")));


ALTER VIEW "public"."vw_aluno_completo" OWNER TO "postgres";


COMMENT ON VIEW "public"."vw_aluno_completo" IS 'View que combina dados do aluno com informações de autenticação';



CREATE OR REPLACE VIEW "public"."vw_alunos_por_profissional" AS
 WITH "vinculos_agregados" AS (
         SELECT "aluno_profissional"."profissional_id",
            "aluno_profissional"."aluno_id",
            "array_agg"(DISTINCT "aluno_profissional"."tipo_profissional" ORDER BY "aluno_profissional"."tipo_profissional") AS "tipos_atendimento",
            "max"(
                CASE
                    WHEN "aluno_profissional"."is_active" THEN "aluno_profissional"."data_inicio"
                    ELSE NULL::"date"
                END) AS "data_inicio",
            "max"(
                CASE
                    WHEN "aluno_profissional"."is_active" THEN "aluno_profissional"."data_fim"
                    ELSE NULL::"date"
                END) AS "data_fim",
            "bool_or"("aluno_profissional"."is_active") AS "is_active",
            "string_agg"(DISTINCT "aluno_profissional"."observacoes", '; '::"text") AS "observacoes"
           FROM "public"."aluno_profissional"
          WHERE ("aluno_profissional"."is_active" = true)
          GROUP BY "aluno_profissional"."profissional_id", "aluno_profissional"."aluno_id"
        )
 SELECT "va"."profissional_id",
    "va"."aluno_id",
    "prof"."nome_completo" AS "profissional_nome",
    "prof"."email" AS "profissional_email",
    "prof"."whatsapp" AS "profissional_whatsapp",
    "prof"."role" AS "profissional_role",
    "a"."nome_completo" AS "aluno_nome",
    "a"."email" AS "aluno_email",
    "a"."whatsapp" AS "aluno_whatsapp",
    "a"."avatar_url" AS "aluno_avatar",
    "a"."subscription_status",
    "a"."is_onboarding_complete",
    "a"."created_at" AS "aluno_cadastrado_em",
    "a"."last_interaction_at" AS "aluno_ultima_interacao",
    "va"."tipos_atendimento",
    "va"."data_inicio" AS "vinculo_inicio",
    "va"."data_fim" AS "vinculo_fim",
    "va"."is_active" AS "vinculo_ativo",
    "va"."observacoes" AS "vinculo_observacoes",
    "c"."codigo" AS "codigo_convite",
    "c"."status" AS "status_convite",
    "c"."data_ativacao" AS "convite_ativado_em",
    "op"."id" AS "onboarding_id",
    "op"."status" AS "onboarding_status",
    "op"."data_criacao" AS "onboarding_data_envio",
    "op"."tem_dieta_atual",
    "op"."tem_treino_atual"
   FROM (((("vinculos_agregados" "va"
     JOIN "public"."alunos" "a" ON (("va"."aluno_id" = "a"."id")))
     JOIN "public"."alunos" "prof" ON (("va"."profissional_id" = "prof"."id")))
     LEFT JOIN LATERAL ( SELECT "convites_alunos"."codigo",
            "convites_alunos"."status",
            "convites_alunos"."data_ativacao"
           FROM "public"."convites_alunos"
          WHERE (("convites_alunos"."aluno_id" = "a"."id") AND ("convites_alunos"."profissional_id" = "prof"."id"))
          ORDER BY "convites_alunos"."data_criacao" DESC
         LIMIT 1) "c" ON (true))
     LEFT JOIN "public"."onboarding_pendente" "op" ON (("op"."aluno_id" = "a"."id")));


ALTER VIEW "public"."vw_alunos_por_profissional" OWNER TO "postgres";


COMMENT ON VIEW "public"."vw_alunos_por_profissional" IS 'Lista todos os alunos ativos de cada profissional com dados completos do vínculo';



CREATE OR REPLACE VIEW "public"."vw_alunos_sem_profissional" AS
 SELECT "a"."id",
    "a"."nome_completo",
    "a"."whatsapp",
    "a"."email",
    "a"."created_at",
    "a"."subscription_status",
    "op"."id" AS "onboarding_id",
    "op"."status" AS "onboarding_status",
    "op"."data_criacao" AS "onboarding_data_envio",
    "op"."tem_dieta_atual",
    "op"."tem_treino_atual",
    "op"."dieta_atual_texto",
    "op"."treino_atual_texto",
    "op"."observacoes_profissional_nutri",
    "op"."observacoes_profissional_personal",
    "op"."whatsapp_aluno"
   FROM ("public"."alunos" "a"
     LEFT JOIN "public"."onboarding_pendente" "op" ON (("op"."aluno_id" = "a"."id")))
  WHERE (("a"."role" = 'aluno'::"public"."user_role") AND (NOT (EXISTS ( SELECT 1
           FROM "public"."aluno_profissional" "ap"
          WHERE (("ap"."aluno_id" = "a"."id") AND ("ap"."is_active" = true))))));


ALTER VIEW "public"."vw_alunos_sem_profissional" OWNER TO "postgres";


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



CREATE OR REPLACE VIEW "public"."vw_metricas_hoje_por_aluno" AS
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    CURRENT_DATE AS "data",
    "count"(*) AS "total_chamadas",
    "sum"("um"."input_tokens") AS "total_input_tokens",
    "sum"("um"."output_tokens") AS "total_output_tokens",
    COALESCE("sum"("um"."cached_tokens"), (0)::bigint) AS "total_cached_tokens",
    ("sum"("um"."input_tokens") - COALESCE("sum"("um"."cached_tokens"), (0)::bigint)) AS "input_tokens_faturados",
    (((((("sum"("um"."input_tokens") - COALESCE("sum"("um"."cached_tokens"), (0)::bigint)))::numeric * 2.0) / (1000000)::numeric) + ((("sum"("um"."output_tokens"))::numeric * 12.0) / (1000000)::numeric)) + (((COALESCE("sum"("um"."cached_tokens"), (0)::bigint))::numeric * 0.15) / (1000000)::numeric)) AS "gasto_diario_usd"
   FROM ("public"."usage_metrics" "um"
     JOIN "public"."alunos" "a" ON (("um"."aluno_id" = "a"."id")))
  WHERE ("date"("um"."created_at") = CURRENT_DATE)
  GROUP BY "a"."id", "a"."nome_completo"
  ORDER BY CURRENT_DATE DESC, "a"."nome_completo";


ALTER VIEW "public"."vw_metricas_hoje_por_aluno" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_nutricao_hoje_por_aluno" AS
 WITH "daily_data" AS (
         SELECT "daily_consumption_history"."aluno_id",
            "daily_consumption_history"."data_registro",
            "sum"("daily_consumption_history"."consumo_calorias") AS "total_calorias_consumidas",
            "sum"("daily_consumption_history"."consumo_proteina") AS "total_proteina_consumida",
            "sum"("daily_consumption_history"."consumo_carboidrato") AS "total_carboidrato_consumido",
            "sum"("daily_consumption_history"."consumo_gordura") AS "total_gordura_consumida",
            "sum"("daily_consumption_history"."consumo_agua_ml") AS "total_agua_consumida"
           FROM "public"."daily_consumption_history"
          WHERE (("daily_consumption_history"."data_registro" = ((CURRENT_DATE AT TIME ZONE 'America/Sao_Paulo'::"text"))::"date") AND ("daily_consumption_history"."confirmada" = true))
          GROUP BY "daily_consumption_history"."aluno_id", "daily_consumption_history"."data_registro"
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    "d"."data_registro",
    (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric AS "meta_calorias",
    (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric AS "meta_proteina",
    (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric AS "meta_carboidratos",
    (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric AS "meta_gorduras",
    (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric AS "meta_agua_ml",
    COALESCE("d"."total_calorias_consumidas", (0)::bigint) AS "total_calorias_consumidas",
    COALESCE("d"."total_proteina_consumida", (0)::bigint) AS "total_proteina_consumida",
    COALESCE("d"."total_carboidrato_consumido", (0)::bigint) AS "total_carboidrato_consumido",
    COALESCE("d"."total_gordura_consumida", (0)::bigint) AS "total_gordura_consumida",
    COALESCE("d"."total_agua_consumida", (0)::bigint) AS "total_agua_consumida",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric > (0)::numeric) THEN "round"((((COALESCE("d"."total_calorias_consumidas", (0)::bigint))::numeric / (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_calorias",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric > (0)::numeric) THEN "round"((((COALESCE("d"."total_proteina_consumida", (0)::bigint))::numeric / (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_proteina",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric > (0)::numeric) THEN "round"((((COALESCE("d"."total_carboidrato_consumido", (0)::bigint))::numeric / (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_carboidratos",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric > (0)::numeric) THEN "round"((((COALESCE("d"."total_gordura_consumida", (0)::bigint))::numeric / (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_gorduras",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric > (0)::numeric) THEN "round"((((COALESCE("d"."total_agua_consumida", (0)::bigint))::numeric / (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_agua"
   FROM (("public"."alunos" "a"
     LEFT JOIN "daily_data" "d" ON (("a"."id" = "d"."aluno_id")))
     LEFT JOIN "public"."diet_plans" "dp" ON ((("a"."id" = "dp"."aluno_id") AND ("dp"."is_active" = true))))
  WHERE ("dp"."id" IS NOT NULL);


ALTER VIEW "public"."vw_nutricao_hoje_por_aluno" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."vw_nutricao_resumo_diario" AS
 WITH "daily_data" AS (
         SELECT "daily_consumption_history"."aluno_id",
            "daily_consumption_history"."data_registro",
            "sum"("daily_consumption_history"."consumo_calorias") AS "total_calorias_consumidas",
            "sum"("daily_consumption_history"."consumo_proteina") AS "total_proteina_consumida",
            "sum"("daily_consumption_history"."consumo_carboidrato") AS "total_carboidrato_consumido",
            "sum"("daily_consumption_history"."consumo_gordura") AS "total_gordura_consumida",
            "sum"("daily_consumption_history"."consumo_agua_ml") AS "total_agua_consumida"
           FROM "public"."daily_consumption_history"
          GROUP BY "daily_consumption_history"."aluno_id", "daily_consumption_history"."data_registro"
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    "d"."data_registro",
    (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric AS "meta_calorias",
    (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric AS "meta_proteina",
    (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric AS "meta_carboidratos",
    (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric AS "meta_gorduras",
    (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric AS "meta_agua_ml",
    "d"."total_calorias_consumidas",
    "d"."total_proteina_consumida",
    "d"."total_carboidrato_consumido",
    "d"."total_gordura_consumida",
    "d"."total_agua_consumida",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric > (0)::numeric) THEN "round"(((("d"."total_calorias_consumidas")::numeric / (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_calorias",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric > (0)::numeric) THEN "round"(((("d"."total_proteina_consumida")::numeric / (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_proteina",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric > (0)::numeric) THEN "round"(((("d"."total_carboidrato_consumido")::numeric / (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_carboidratos",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric > (0)::numeric) THEN "round"(((("d"."total_gordura_consumida")::numeric / (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_gorduras",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric > (0)::numeric) THEN "round"(((("d"."total_agua_consumida")::numeric / (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_agua"
   FROM (("daily_data" "d"
     JOIN "public"."alunos" "a" ON (("d"."aluno_id" = "a"."id")))
     JOIN "public"."diet_plans" "dp" ON ((("d"."aluno_id" = "dp"."aluno_id") AND ("dp"."is_active" = true))))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."vw_nutricao_resumo_diario" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "public"."vw_nutricao_resumo_diario" IS 'Visão materializada que consolida o consumo diário de cada aluno, comparando com suas metas e calculando os percentuais de aderência.';



CREATE MATERIALIZED VIEW "public"."vw_nutricao_resumo_mensal" AS
 WITH "monthly_data" AS (
         SELECT "daily_consumption_history"."aluno_id",
            ("date_trunc"('month'::"text", ("daily_consumption_history"."data_registro")::timestamp with time zone))::"date" AS "mes_inicio",
            (((("date_trunc"('month'::"text", ("daily_consumption_history"."data_registro")::timestamp with time zone))::"date" + '1 mon'::interval) - '1 day'::interval))::"date" AS "mes_fim",
            "sum"("daily_consumption_history"."consumo_calorias") AS "total_calorias_consumidas",
            "sum"("daily_consumption_history"."consumo_proteina") AS "total_proteina_consumida",
            "sum"("daily_consumption_history"."consumo_carboidrato") AS "total_carboidrato_consumido",
            "sum"("daily_consumption_history"."consumo_gordura") AS "total_gordura_consumida",
            "sum"("daily_consumption_history"."consumo_agua_ml") AS "total_agua_consumida",
            "count"(*) AS "dias_registrados"
           FROM "public"."daily_consumption_history"
          GROUP BY "daily_consumption_history"."aluno_id", (("date_trunc"('month'::"text", ("daily_consumption_history"."data_registro")::timestamp with time zone))::"date")
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    "w"."mes_inicio",
    "w"."mes_fim",
    "w"."dias_registrados",
    EXTRACT(day FROM "w"."mes_fim") AS "dias_no_mes",
    (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric AS "meta_calorias_dia",
    (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric AS "meta_proteina_dia",
    (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric AS "meta_carboidratos_dia",
    (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric AS "meta_gorduras_dia",
    (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric AS "meta_agua_ml_dia",
    ((("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric * EXTRACT(day FROM "w"."mes_fim")) AS "meta_calorias_mes",
    ((("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric * EXTRACT(day FROM "w"."mes_fim")) AS "meta_proteina_mes",
    ((("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric * EXTRACT(day FROM "w"."mes_fim")) AS "meta_carboidratos_mes",
    ((("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric * EXTRACT(day FROM "w"."mes_fim")) AS "meta_gorduras_mes",
    ((("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric * EXTRACT(day FROM "w"."mes_fim")) AS "meta_agua_ml_mes",
    "w"."total_calorias_consumidas",
    "w"."total_proteina_consumida",
    "w"."total_carboidrato_consumido",
    "w"."total_gordura_consumida",
    "w"."total_agua_consumida",
    "round"((("w"."total_calorias_consumidas" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_calorias_dia",
    "round"((("w"."total_proteina_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_proteina_dia",
    "round"((("w"."total_carboidrato_consumido" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_carboidratos_dia",
    "round"((("w"."total_gordura_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_gorduras_dia",
    "round"((("w"."total_agua_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_agua_ml_dia",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_calorias_consumidas" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_calorias",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_proteina_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_proteina",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_carboidrato_consumido" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_carboidratos",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_gordura_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_gorduras",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_agua_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_agua"
   FROM (("monthly_data" "w"
     JOIN "public"."alunos" "a" ON (("w"."aluno_id" = "a"."id")))
     LEFT JOIN "public"."diet_plans" "dp" ON ((("w"."aluno_id" = "dp"."aluno_id") AND ("dp"."is_active" = true))))
  ORDER BY "a"."id", "w"."mes_inicio" DESC
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."vw_nutricao_resumo_mensal" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "public"."vw_nutricao_resumo_mensal" IS 'Histórico completo de consumo nutricional agrupado por mês. Uma linha para cada mês desde o primeiro registro. Atualizado automaticamente todo dia 1 às 03:00. Mostra totais mensais, médias diárias e percentuais de aderência.';



CREATE MATERIALIZED VIEW "public"."vw_nutricao_resumo_semanal" AS
 WITH "weekly_data" AS (
         SELECT "daily_consumption_history"."aluno_id",
            ("date_trunc"('week'::"text", ("daily_consumption_history"."data_registro")::timestamp with time zone))::"date" AS "semana_inicio",
            ((("date_trunc"('week'::"text", ("daily_consumption_history"."data_registro")::timestamp with time zone))::"date" + '6 days'::interval))::"date" AS "semana_fim",
            "sum"("daily_consumption_history"."consumo_calorias") AS "total_calorias_consumidas",
            "sum"("daily_consumption_history"."consumo_proteina") AS "total_proteina_consumida",
            "sum"("daily_consumption_history"."consumo_carboidrato") AS "total_carboidrato_consumido",
            "sum"("daily_consumption_history"."consumo_gordura") AS "total_gordura_consumida",
            "sum"("daily_consumption_history"."consumo_agua_ml") AS "total_agua_consumida",
            "count"(*) AS "dias_registrados"
           FROM "public"."daily_consumption_history"
          GROUP BY "daily_consumption_history"."aluno_id", (("date_trunc"('week'::"text", ("daily_consumption_history"."data_registro")::timestamp with time zone))::"date")
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    "w"."semana_inicio",
    "w"."semana_fim",
    "w"."dias_registrados",
    (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric AS "meta_calorias_dia",
    (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric AS "meta_proteina_dia",
    (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric AS "meta_carboidratos_dia",
    (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric AS "meta_gorduras_dia",
    (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric AS "meta_agua_ml_dia",
    ((("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric * (7)::numeric) AS "meta_calorias_semana",
    ((("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric * (7)::numeric) AS "meta_proteina_semana",
    ((("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric * (7)::numeric) AS "meta_carboidratos_semana",
    ((("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric * (7)::numeric) AS "meta_gorduras_semana",
    ((("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric * (7)::numeric) AS "meta_agua_ml_semana",
    "w"."total_calorias_consumidas",
    "w"."total_proteina_consumida",
    "w"."total_carboidrato_consumido",
    "w"."total_gordura_consumida",
    "w"."total_agua_consumida",
    "round"((("w"."total_calorias_consumidas" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_calorias_dia",
    "round"((("w"."total_proteina_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_proteina_dia",
    "round"((("w"."total_carboidrato_consumido" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_carboidratos_dia",
    "round"((("w"."total_gordura_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_gorduras_dia",
    "round"((("w"."total_agua_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric, 1) AS "media_agua_ml_dia",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_calorias_consumidas" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'calorias'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_calorias",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_proteina_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'proteinas'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_proteina",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_carboidrato_consumido" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'carboidratos'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_carboidratos",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_gordura_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'gorduras'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_gorduras",
        CASE
            WHEN ((("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric > (0)::numeric) THEN "round"((((("w"."total_agua_consumida" / NULLIF("w"."dias_registrados", 0)))::numeric / (("dp"."meta_diaria_geral" ->> 'agua_ml'::"text"))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_agua"
   FROM (("weekly_data" "w"
     JOIN "public"."alunos" "a" ON (("w"."aluno_id" = "a"."id")))
     LEFT JOIN "public"."diet_plans" "dp" ON ((("w"."aluno_id" = "dp"."aluno_id") AND ("dp"."is_active" = true))))
  ORDER BY "a"."id", "w"."semana_inicio" DESC
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."vw_nutricao_resumo_semanal" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "public"."vw_nutricao_resumo_semanal" IS 'Histórico completo de consumo nutricional agrupado por semana. Uma linha para cada semana desde o primeiro registro. Atualizado automaticamente toda segunda-feira às 01:00.';



CREATE OR REPLACE VIEW "public"."vw_perfil_completo_aluno" AS
 WITH "medidas_iniciais" AS (
         SELECT "bm"."id",
            "bm"."aluno_id",
            "bm"."data_medicao",
            "bm"."peso_kg",
            "bm"."altura_cm",
            "bm"."circunferencia_pescoco_cm",
            "bm"."circunferencia_cintura_cm",
            "bm"."circunferencia_quadril_cm",
            "bm"."percentual_gordura",
            "bm"."fotos_urls",
            "bm"."created_at",
            "bm"."notas",
            "bm"."feedback_subjetivo",
            "bm"."circunferencia_peito_cm",
            "bm"."medidas_json",
            "row_number"() OVER (PARTITION BY "bm"."aluno_id" ORDER BY "bm"."data_medicao", "bm"."created_at") AS "rn"
           FROM "public"."body_metrics" "bm"
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo",
    "a"."whatsapp",
    "sr"."id" AS "saude_e_rotina_id",
    "g"."id" AS "goal_id_ativo",
    "pa"."id" AS "preferencias_alimentares_id",
    "pt"."id" AS "preferencias_treino_id",
    "mi"."id" AS "medidas_iniciais_id",
    "date_part"('year'::"text", "age"(("sr"."data_nascimento")::timestamp with time zone)) AS "idade",
    "sr"."altura_cm",
    "g"."valor_inicial" AS "peso_inicial_meta",
    "g"."valor_meta" AS "meta_de_peso",
    "g"."nome_meta" AS "objetivo_principal",
    ( SELECT "instrucoes_nutricionista"."instrucoes_texto"
           FROM "public"."instrucoes_nutricionista"
          WHERE ("instrucoes_nutricionista"."aluno_id" = "a"."id")) AS "anotacoes_nutricionista",
    ( SELECT "instrucoes_personal"."instrucoes_texto"
           FROM "public"."instrucoes_personal"
          WHERE ("instrucoes_personal"."aluno_id" = "a"."id")) AS "anotacoes_personal",
    "sr"."condicoes_medicas",
    "sr"."medicacoes_em_uso",
    "sr"."alergias",
    "sr"."lesoes_limitacoes",
    "g"."metrica_primaria" AS "tipo_meta",
    "g"."data_fim" AS "prazo_meta",
    "g"."motivacao_principal" AS "motivacao_meta",
    "sr"."profissao",
    "sr"."horario_acordar",
    "sr"."horario_dormir",
    "pa"."restricoes_alimentares",
    "pa"."alimentos_nao_gosta",
    "pa"."alimentos_favoritos",
    "pa"."disposicao_cozinhar",
    "pa"."orcamento_alimentar",
    "pt"."local_treino",
    "pt"."equipamentos_disponiveis",
    "pt"."experiencia_treino",
    "pt"."dias_preferenciais_treino",
    "pt"."horarios_preferenciais_treino",
    "mi"."data_medicao" AS "data_medidas_iniciais",
    "mi"."peso_kg" AS "peso_medidas_iniciais",
    "mi"."altura_cm" AS "altura_medidas_iniciais",
    "mi"."circunferencia_pescoco_cm" AS "pescoco_inicial",
    "mi"."circunferencia_peito_cm" AS "peito_inicial",
    "mi"."circunferencia_cintura_cm" AS "cintura_inicial",
    "mi"."circunferencia_quadril_cm" AS "quadril_inicial",
    "mi"."percentual_gordura" AS "gordura_inicial",
    "mi"."notas" AS "notas_medidas_iniciais",
    (("mi"."medidas_json" ->> 'braco_dir'::"text"))::numeric AS "braco_dir_inicial",
    (("mi"."medidas_json" ->> 'braco_esq'::"text"))::numeric AS "braco_esq_inicial",
    (("mi"."medidas_json" ->> 'coxa_dir'::"text"))::numeric AS "coxa_dir_inicial",
    (("mi"."medidas_json" ->> 'coxa_esq'::"text"))::numeric AS "coxa_esq_inicial",
    (("mi"."medidas_json" ->> 'panturrilha_dir'::"text"))::numeric AS "panturrilha_dir_inicial",
    (("mi"."medidas_json" ->> 'panturrilha_esq'::"text"))::numeric AS "panturrilha_esq_inicial"
   FROM ((((("public"."alunos" "a"
     LEFT JOIN "public"."saude_e_rotina" "sr" ON (("a"."id" = "sr"."aluno_id")))
     LEFT JOIN "public"."goals" "g" ON ((("a"."id" = "g"."aluno_id") AND (("g"."status")::"text" = 'ativo'::"text"))))
     LEFT JOIN "public"."preferencias_alimentares" "pa" ON (("a"."id" = "pa"."aluno_id")))
     LEFT JOIN "public"."preferencias_treino" "pt" ON (("a"."id" = "pt"."aluno_id")))
     LEFT JOIN "medidas_iniciais" "mi" ON ((("a"."id" = "mi"."aluno_id") AND ("mi"."rn" = 1))));


ALTER VIEW "public"."vw_perfil_completo_aluno" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_teste_semana_atual" AS
 SELECT "aluno_id",
    "nome_aluno",
    "data_registro",
    "meta_calorias",
    "meta_proteina",
    "meta_carboidratos",
    "meta_gorduras",
    "meta_agua_ml",
    "total_calorias_consumidas",
    "total_proteina_consumida",
    "total_carboidrato_consumido",
    "total_gordura_consumida",
    "total_agua_consumida",
    "percentual_calorias",
    "percentual_proteina",
    "percentual_carboidratos",
    "percentual_gorduras",
    "percentual_agua"
   FROM "public"."vw_nutricao_resumo_diario"
  WHERE (("data_registro" >= ("date_trunc"('week'::"text", (CURRENT_DATE)::timestamp with time zone))::"date") AND ("data_registro" <= CURRENT_DATE));


ALTER VIEW "public"."vw_teste_semana_atual" OWNER TO "postgres";


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
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "criado_por_profissional_id" "uuid"
);


ALTER TABLE "public"."workout_programs" OWNER TO "postgres";


COMMENT ON TABLE "public"."workout_programs" IS 'Tabela mestre para um programa de treino. Contém os metadados gerais do programa ativo ou de versões anteriores.';



COMMENT ON COLUMN "public"."workout_programs"."nome_programa" IS 'Nome do programa (ex: "Hipertrofia Upper/Lower 4x").';



COMMENT ON COLUMN "public"."workout_programs"."criado_por_profissional_id" IS 'ID do profissional (nutricionista/personal/master) que criou este programa de treino';



CREATE MATERIALIZED VIEW "public"."vw_treino_resumo_diario" AS
 WITH "treinos_planejados" AS (
         SELECT "wp"."aluno_id",
            "gs"."data_treino",
            "count"(DISTINCT "pw"."id") AS "treinos_planejados"
           FROM (("public"."workout_programs" "wp"
             CROSS JOIN LATERAL "generate_series"(("wp"."data_inicio")::timestamp with time zone, (COALESCE("wp"."data_fim", CURRENT_DATE))::timestamp with time zone, '1 day'::interval) "gs"("data_treino"))
             JOIN "public"."program_workouts" "pw" ON (("wp"."id" = "pw"."program_id")))
          WHERE (("wp"."is_active" = true) AND ("pw"."dia_da_semana" = (EXTRACT(dow FROM "gs"."data_treino"))::smallint))
          GROUP BY "wp"."aluno_id", "gs"."data_treino"
        ), "treinos_executados" AS (
         SELECT "dwe"."aluno_id",
            "dwe"."data_treino",
            "count"(*) AS "treinos_realizados",
            "string_agg"(COALESCE("dwe"."descricao_atividade", ("pw"."nome_treino")::"text"), ', '::"text" ORDER BY "dwe"."created_at") AS "atividades_realizadas"
           FROM ("public"."daily_workout_executions" "dwe"
             LEFT JOIN "public"."program_workouts" "pw" ON (("dwe"."program_workout_id" = "pw"."id")))
          GROUP BY "dwe"."aluno_id", "dwe"."data_treino"
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    COALESCE("tp"."data_treino", ("te"."data_treino")::timestamp with time zone) AS "data_treino",
    COALESCE("tp"."treinos_planejados", (0)::bigint) AS "treinos_planejados",
    COALESCE("te"."treinos_realizados", (0)::bigint) AS "treinos_realizados",
        CASE
            WHEN (COALESCE("tp"."treinos_planejados", (0)::bigint) > 0) THEN "round"((((COALESCE("te"."treinos_realizados", (0)::bigint))::numeric / ("tp"."treinos_planejados")::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_aderencia",
    "te"."atividades_realizadas",
        CASE
            WHEN ("te"."treinos_realizados" IS NULL) THEN 'nao_treinou'::"text"
            WHEN ("te"."treinos_realizados" >= "tp"."treinos_planejados") THEN 'completo'::"text"
            WHEN ("te"."treinos_realizados" > 0) THEN 'parcial'::"text"
            ELSE 'nao_treinou'::"text"
        END AS "status_dia"
   FROM (("public"."alunos" "a"
     LEFT JOIN "treinos_planejados" "tp" ON (("a"."id" = "tp"."aluno_id")))
     LEFT JOIN "treinos_executados" "te" ON ((("a"."id" = "te"."aluno_id") AND ("tp"."data_treino" = "te"."data_treino"))))
  WHERE (COALESCE("tp"."data_treino", ("te"."data_treino")::timestamp with time zone) IS NOT NULL)
  ORDER BY "a"."id", COALESCE("tp"."data_treino", ("te"."data_treino")::timestamp with time zone) DESC
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."vw_treino_resumo_diario" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "public"."vw_treino_resumo_diario" IS 'Resumo diário de aderência ao treino. Compara treinos planejados vs executados por dia.';



CREATE MATERIALIZED VIEW "public"."vw_treino_resumo_mensal" AS
 WITH "treinos_no_programa" AS (
         SELECT "wp"."aluno_id",
            "count"(DISTINCT "pw"."id") AS "total_treinos_programa"
           FROM ("public"."workout_programs" "wp"
             JOIN "public"."program_workouts" "pw" ON (("wp"."id" = "pw"."program_id")))
          WHERE ("wp"."is_active" = true)
          GROUP BY "wp"."aluno_id"
        ), "execucoes_mensais" AS (
         SELECT "dwe"."aluno_id",
            ("date_trunc"('month'::"text", ("dwe"."data_treino")::timestamp with time zone))::"date" AS "mes_inicio",
            (((("date_trunc"('month'::"text", ("dwe"."data_treino")::timestamp with time zone))::"date" + '1 mon'::interval) - '1 day'::interval))::"date" AS "mes_fim",
            "count"(*) AS "treinos_executados",
            "count"(DISTINCT "dwe"."data_treino") AS "dias_treinou",
            "string_agg"(DISTINCT COALESCE("dwe"."descricao_atividade", ("pw"."nome_treino")::"text"), ', '::"text" ORDER BY COALESCE("dwe"."descricao_atividade", ("pw"."nome_treino")::"text")) AS "atividades_realizadas"
           FROM ("public"."daily_workout_executions" "dwe"
             LEFT JOIN "public"."program_workouts" "pw" ON (("dwe"."program_workout_id" = "pw"."id")))
          GROUP BY "dwe"."aluno_id", (("date_trunc"('month'::"text", ("dwe"."data_treino")::timestamp with time zone))::"date")
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    "em"."mes_inicio",
    "em"."mes_fim",
    EXTRACT(day FROM "em"."mes_fim") AS "total_dias_mes",
    ("tp"."total_treinos_programa" * 4) AS "treinos_planejados_mes",
    "tp"."total_treinos_programa" AS "treinos_programa",
    "em"."treinos_executados",
    "em"."dias_treinou",
        CASE
            WHEN (("tp"."total_treinos_programa" * 4) > 0) THEN "round"(((("em"."treinos_executados")::numeric / (("tp"."total_treinos_programa" * 4))::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_aderencia",
    "em"."atividades_realizadas",
    "round"((("em"."treinos_executados")::numeric / 4.0), 1) AS "media_treinos_semana",
        CASE
            WHEN ("em"."treinos_executados" >= ("tp"."total_treinos_programa" * 4)) THEN 'completo'::"text"
            WHEN (("em"."treinos_executados")::numeric >= (("tp"."total_treinos_programa")::numeric * 3.2)) THEN 'excelente'::"text"
            WHEN (("em"."treinos_executados")::numeric >= (("tp"."total_treinos_programa")::numeric * 2.4)) THEN 'bom'::"text"
            WHEN (("em"."treinos_executados")::numeric >= (("tp"."total_treinos_programa")::numeric * 1.6)) THEN 'regular'::"text"
            WHEN ("em"."treinos_executados" > 0) THEN 'baixo'::"text"
            ELSE 'nao_treinou'::"text"
        END AS "status_mes"
   FROM (("execucoes_mensais" "em"
     JOIN "public"."alunos" "a" ON (("em"."aluno_id" = "a"."id")))
     LEFT JOIN "treinos_no_programa" "tp" ON (("em"."aluno_id" = "tp"."aluno_id")))
  ORDER BY "a"."id", "em"."mes_inicio" DESC
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."vw_treino_resumo_mensal" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "public"."vw_treino_resumo_mensal" IS 'Resumo mensal de treinos. Estimativa: treinos planejados = número de treinos no programa × 4 semanas. Atualizado todo dia 1 às 03:00.';



CREATE MATERIALIZED VIEW "public"."vw_treino_resumo_semanal" AS
 WITH "treinos_no_programa" AS (
         SELECT "wp"."aluno_id",
            "count"(DISTINCT "pw"."id") AS "total_treinos_programa"
           FROM ("public"."workout_programs" "wp"
             JOIN "public"."program_workouts" "pw" ON (("wp"."id" = "pw"."program_id")))
          WHERE ("wp"."is_active" = true)
          GROUP BY "wp"."aluno_id"
        ), "execucoes_semanais" AS (
         SELECT "dwe"."aluno_id",
            ("date_trunc"('week'::"text", ("dwe"."data_treino")::timestamp with time zone))::"date" AS "semana_inicio",
            ((("date_trunc"('week'::"text", ("dwe"."data_treino")::timestamp with time zone))::"date" + '6 days'::interval))::"date" AS "semana_fim",
            "count"(*) AS "treinos_executados",
            "count"(DISTINCT "dwe"."data_treino") AS "dias_treinou",
            "string_agg"(DISTINCT COALESCE("dwe"."descricao_atividade", ("pw"."nome_treino")::"text"), ', '::"text" ORDER BY COALESCE("dwe"."descricao_atividade", ("pw"."nome_treino")::"text")) AS "atividades_realizadas"
           FROM ("public"."daily_workout_executions" "dwe"
             LEFT JOIN "public"."program_workouts" "pw" ON (("dwe"."program_workout_id" = "pw"."id")))
          GROUP BY "dwe"."aluno_id", (("date_trunc"('week'::"text", ("dwe"."data_treino")::timestamp with time zone))::"date")
        )
 SELECT "a"."id" AS "aluno_id",
    "a"."nome_completo" AS "nome_aluno",
    "es"."semana_inicio",
    "es"."semana_fim",
    "tp"."total_treinos_programa",
    "es"."treinos_executados",
    "es"."dias_treinou",
        CASE
            WHEN ("tp"."total_treinos_programa" > 0) THEN "round"(((("es"."treinos_executados")::numeric / ("tp"."total_treinos_programa")::numeric) * (100)::numeric))
            ELSE (0)::numeric
        END AS "percentual_aderencia",
    "es"."atividades_realizadas",
        CASE
            WHEN ("es"."treinos_executados" >= "tp"."total_treinos_programa") THEN 'completo'::"text"
            WHEN (("es"."treinos_executados")::numeric >= (("tp"."total_treinos_programa")::numeric * 0.7)) THEN 'bom'::"text"
            WHEN (("es"."treinos_executados")::numeric >= (("tp"."total_treinos_programa")::numeric * 0.5)) THEN 'regular'::"text"
            WHEN ("es"."treinos_executados" > 0) THEN 'baixo'::"text"
            ELSE 'nao_treinou'::"text"
        END AS "status_semana"
   FROM (("execucoes_semanais" "es"
     JOIN "public"."alunos" "a" ON (("es"."aluno_id" = "a"."id")))
     LEFT JOIN "treinos_no_programa" "tp" ON (("es"."aluno_id" = "tp"."aluno_id")))
  ORDER BY "a"."id", "es"."semana_inicio" DESC
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."vw_treino_resumo_semanal" OWNER TO "postgres";


COMMENT ON MATERIALIZED VIEW "public"."vw_treino_resumo_semanal" IS 'Resumo semanal de treinos. Compara quantos treinos existem no programa vs quantos foram executados. Atualizado toda segunda-feira às 01:00.';



CREATE TABLE IF NOT EXISTS "public"."workout_exercises" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "workout_id" "uuid" NOT NULL,
    "ordem" smallint,
    "nome_exercicio" character varying(255) NOT NULL,
    "series" character varying(20),
    "repeticoes" character varying(20),
    "carga_kg" numeric,
    "descanso_segundos" smallint,
    "observacoes" "text",
    "exercicio_template_id" integer,
    "grupo_muscular" "text",
    "ativo" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."workout_exercises" OWNER TO "postgres";


COMMENT ON TABLE "public"."workout_exercises" IS 'Detalha cada exercício dentro de um treino específico, permitindo fácil atualização de cargas e outros parâmetros.';



COMMENT ON COLUMN "public"."workout_exercises"."carga_kg" IS 'A carga recomendada para o exercício. Este campo será frequentemente atualizado.';



COMMENT ON COLUMN "public"."workout_exercises"."exercicio_template_id" IS 'FK para a tabela exercicios_template. Padroniza o exercício.';



COMMENT ON COLUMN "public"."workout_exercises"."grupo_muscular" IS 'Dado desnormalizado (copiado do template) para otimizar queries rápidas do chatbot, evitando joins.';



COMMENT ON COLUMN "public"."workout_exercises"."ativo" IS 'Indica se o exercício está ativo no programa. FALSE quando substituído por outro.';



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



ALTER TABLE ONLY "public"."exercicios_template" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."exercicios_template_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."aluno_profissional"
    ADD CONSTRAINT "aluno_profissional_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."body_metrics"
    ADD CONSTRAINT "body_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."botoes_ativos"
    ADD CONSTRAINT "botoes_ativos_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."botoes_ativos"
    ADD CONSTRAINT "botoes_ativos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."completions_old"
    ADD CONSTRAINT "completions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."config_sistema"
    ADD CONSTRAINT "config_sistema_pkey" PRIMARY KEY ("chave");



ALTER TABLE ONLY "public"."convites_alunos"
    ADD CONSTRAINT "convites_alunos_codigo_key" UNIQUE ("codigo");



ALTER TABLE ONLY "public"."convites_alunos"
    ADD CONSTRAINT "convites_alunos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_consumption_history"
    ADD CONSTRAINT "daily_consumption_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_workout_executions"
    ADD CONSTRAINT "daily_workout_executions_pkey" PRIMARY KEY ("id");



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



ALTER TABLE ONLY "public"."exercicios_template"
    ADD CONSTRAINT "exercicios_template_nome_exercicio_key" UNIQUE ("nome_exercicio");



ALTER TABLE ONLY "public"."exercicios_template"
    ADD CONSTRAINT "exercicios_template_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."food_items"
    ADD CONSTRAINT "food_items_categoria_nome_key" UNIQUE ("categoria", "nome");



ALTER TABLE ONLY "public"."food_items"
    ADD CONSTRAINT "food_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."funcoes_ia"
    ADD CONSTRAINT "funcoes_ia_nome_funcao_key" UNIQUE ("nome_funcao");



ALTER TABLE ONLY "public"."funcoes_ia"
    ADD CONSTRAINT "funcoes_ia_pkey" PRIMARY KEY ("id");



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



ALTER TABLE ONLY "public"."onboarding_pendente"
    ADD CONSTRAINT "onboarding_pendente_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."onboarding_pendente"
    ADD CONSTRAINT "onboarding_pendente_pkey" PRIMARY KEY ("id");



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



ALTER TABLE ONLY "public"."prompts_sistema"
    ADD CONSTRAINT "prompts_sistema_pkey" PRIMARY KEY ("chave");



ALTER TABLE ONLY "public"."saude_e_rotina"
    ADD CONSTRAINT "saude_e_rotina_aluno_id_key" UNIQUE ("aluno_id");



ALTER TABLE ONLY "public"."saude_e_rotina"
    ADD CONSTRAINT "saude_e_rotina_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_workout_executions"
    ADD CONSTRAINT "unique_aluno_data_workout" UNIQUE ("aluno_id", "data_treino", "program_workout_id");



ALTER TABLE ONLY "public"."usage_metrics"
    ADD CONSTRAINT "usage_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workout_exercises"
    ADD CONSTRAINT "workout_exercises_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workout_plans_old"
    ADD CONSTRAINT "workout_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."workout_programs"
    ADD CONSTRAINT "workout_programs_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "alunos_whatsapp_unique_idx" ON "public"."alunos" USING "btree" ("whatsapp") WHERE (("whatsapp" IS NOT NULL) AND (("whatsapp")::"text" <> ''::"text"));



CREATE INDEX "idx_aluno_profissional_active" ON "public"."aluno_profissional" USING "btree" ("is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_aluno_profissional_aluno" ON "public"."aluno_profissional" USING "btree" ("aluno_id");



CREATE INDEX "idx_aluno_profissional_profissional" ON "public"."aluno_profissional" USING "btree" ("profissional_id");



CREATE INDEX "idx_aluno_profissional_tipo" ON "public"."aluno_profissional" USING "btree" ("tipo_profissional");



CREATE UNIQUE INDEX "idx_aluno_profissional_unique_active" ON "public"."aluno_profissional" USING "btree" ("aluno_id", "profissional_id", "tipo_profissional") WHERE ("is_active" = true);



CREATE INDEX "idx_alunos_aguardando" ON "public"."alunos" USING "btree" ((("aguardando_confirmacao" ->> 'aguardando'::"text")));



CREATE UNIQUE INDEX "idx_alunos_auth_user_id" ON "public"."alunos" USING "btree" ("auth_user_id") WHERE ("auth_user_id" IS NOT NULL);



CREATE INDEX "idx_alunos_created_at" ON "public"."alunos" USING "btree" ("created_at");



CREATE INDEX "idx_alunos_email" ON "public"."alunos" USING "btree" ("email") WHERE ("email" IS NOT NULL);



CREATE INDEX "idx_alunos_role" ON "public"."alunos" USING "btree" ("role");



CREATE INDEX "idx_alunos_whatsapp" ON "public"."alunos" USING "btree" ("whatsapp");



CREATE INDEX "idx_body_metrics_aluno_id" ON "public"."body_metrics" USING "btree" ("aluno_id");



CREATE INDEX "idx_body_metrics_data_medicao" ON "public"."body_metrics" USING "btree" ("aluno_id", "data_medicao" DESC);



CREATE INDEX "idx_body_metrics_profissional" ON "public"."body_metrics" USING "btree" ("registrado_por_profissional_id");



CREATE INDEX "idx_botoes_ativos_aluno_id" ON "public"."botoes_ativos" USING "btree" ("aluno_id");



CREATE INDEX "idx_botoes_ativos_created_at" ON "public"."botoes_ativos" USING "btree" ("created_at");



CREATE INDEX "idx_botoes_ativos_tipo_acao" ON "public"."botoes_ativos" USING "btree" ("tipo_acao");



CREATE INDEX "idx_completions_aluno_id" ON "public"."completions_old" USING "btree" ("aluno_id");



CREATE INDEX "idx_completions_created_at" ON "public"."completions_old" USING "btree" ("aluno_id", "created_at" DESC);



CREATE INDEX "idx_completions_nao_processados" ON "public"."completions_old" USING "btree" ("processado", "created_at") WHERE ("processado" = false);



CREATE INDEX "idx_config_sistema_chave" ON "public"."config_sistema" USING "btree" ("chave");



CREATE INDEX "idx_convites_aluno" ON "public"."convites_alunos" USING "btree" ("aluno_id");



CREATE INDEX "idx_convites_codigo" ON "public"."convites_alunos" USING "btree" ("codigo");



CREATE INDEX "idx_convites_expiracao" ON "public"."convites_alunos" USING "btree" ("expira_em") WHERE (("status")::"text" = 'pendente'::"text");



CREATE INDEX "idx_convites_profissional" ON "public"."convites_alunos" USING "btree" ("profissional_id");



CREATE INDEX "idx_convites_status" ON "public"."convites_alunos" USING "btree" ("status") WHERE (("status")::"text" = 'pendente'::"text");



CREATE INDEX "idx_daily_consumption_aluno_date" ON "public"."daily_consumption_history" USING "btree" ("aluno_id", "data_registro" DESC);



CREATE INDEX "idx_daily_consumption_aluno_id" ON "public"."daily_consumption_history" USING "btree" ("aluno_id");



CREATE INDEX "idx_daily_consumption_data" ON "public"."daily_consumption_history" USING "btree" ("aluno_id", "data_registro" DESC);



CREATE INDEX "idx_daily_workout_aluno_id" ON "public"."daily_workout_logs" USING "btree" ("aluno_id");



CREATE INDEX "idx_daily_workout_data" ON "public"."daily_workout_logs" USING "btree" ("aluno_id", "data_treino" DESC);



CREATE INDEX "idx_diet_plans_active" ON "public"."diet_plans" USING "btree" ("aluno_id", "is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_diet_plans_aluno_id" ON "public"."diet_plans" USING "btree" ("aluno_id");



CREATE UNIQUE INDEX "idx_diet_plans_one_active_per_aluno" ON "public"."diet_plans" USING "btree" ("aluno_id") WHERE ("is_active" = true);



CREATE INDEX "idx_diet_plans_profissional" ON "public"."diet_plans" USING "btree" ("criado_por_profissional_id");



CREATE INDEX "idx_diet_plans_version" ON "public"."diet_plans" USING "btree" ("aluno_id", "version" DESC);



CREATE INDEX "idx_dynamic_prompts_active" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id", "is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_dynamic_prompts_aluno" ON "public"."dynamic_prompts" USING "btree" ("aluno_id");



CREATE INDEX "idx_dynamic_prompts_aluno_id" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id");



CREATE INDEX "idx_dynamic_prompts_conversation_id" ON "public"."dynamic_prompts" USING "btree" ("conversation_id");



CREATE INDEX "idx_dynamic_prompts_date" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id", "data_validade" DESC);



CREATE UNIQUE INDEX "idx_dynamic_prompts_unique" ON "public"."dynamic_prompts_old" USING "btree" ("aluno_id", "data_validade") WHERE ("is_active" = true);



CREATE INDEX "idx_food_items_categoria" ON "public"."food_items" USING "btree" ("categoria");



CREATE INDEX "idx_funcoes_ia_active" ON "public"."funcoes_ia" USING "btree" ("is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_goals_aluno_id" ON "public"."goals" USING "btree" ("aluno_id");



CREATE INDEX "idx_goals_profissional" ON "public"."goals" USING "btree" ("criado_por_profissional_id");



CREATE INDEX "idx_historico_aluno_id" ON "public"."historico_atualizacoes_exercicio" USING "btree" ("aluno_id");



CREATE INDEX "idx_historico_exercicio_id" ON "public"."historico_atualizacoes_exercicio" USING "btree" ("exercicio_id");



CREATE INDEX "idx_historico_timestamp" ON "public"."historico_atualizacoes_exercicio" USING "btree" ("timestamp" DESC);



CREATE INDEX "idx_instrucoes_nutricionista_profissional" ON "public"."instrucoes_nutricionista" USING "btree" ("criado_por_profissional_id");



CREATE INDEX "idx_instrucoes_personal_profissional" ON "public"."instrucoes_personal" USING "btree" ("criado_por_profissional_id");



CREATE INDEX "idx_logs_nome_funcao" ON "public"."logs_funcoes" USING "btree" ("nome_funcao");



CREATE INDEX "idx_logs_timestamp" ON "public"."logs_funcoes" USING "btree" ("timestamp" DESC);



CREATE INDEX "idx_mensagens_temp_agregado" ON "public"."mensagens_temporarias" USING "btree" ("agregado") WHERE ("agregado" = false);



CREATE INDEX "idx_mensagens_temp_aluno_id" ON "public"."mensagens_temporarias" USING "btree" ("aluno_id");



CREATE INDEX "idx_mensagens_temp_para_agregacao" ON "public"."mensagens_temporarias" USING "btree" ("aluno_id", "timestamp_recebimento" DESC) WHERE ("agregado" = false);



CREATE INDEX "idx_mensagens_temp_timestamp" ON "public"."mensagens_temporarias" USING "btree" ("aluno_id", "timestamp_recebimento" DESC);



CREATE INDEX "idx_mensagens_temp_whatsapp" ON "public"."mensagens_temporarias" USING "btree" ("whatsapp");



CREATE UNIQUE INDEX "idx_nutricao_diario_unique" ON "public"."vw_nutricao_resumo_diario" USING "btree" ("aluno_id", "data_registro");



CREATE UNIQUE INDEX "idx_nutricao_mensal_unique" ON "public"."vw_nutricao_resumo_mensal" USING "btree" ("aluno_id", "mes_inicio");



CREATE UNIQUE INDEX "idx_nutricao_semanal_unique" ON "public"."vw_nutricao_resumo_semanal" USING "btree" ("aluno_id", "semana_inicio");



CREATE INDEX "idx_onboarding_created" ON "public"."onboarding_pendente" USING "btree" ("data_criacao");



CREATE INDEX "idx_onboarding_dashboard" ON "public"."onboarding_pendente" USING "btree" ("profissional_responsavel_id", "status", "data_criacao");



CREATE INDEX "idx_onboarding_profissional" ON "public"."onboarding_pendente" USING "btree" ("profissional_responsavel_id", "status");



CREATE INDEX "idx_onboarding_status" ON "public"."onboarding_pendente" USING "btree" ("status") WHERE ("status" = ANY (ARRAY['aguardando_analise'::"public"."status_onboarding", 'em_revisao'::"public"."status_onboarding"]));



CREATE INDEX "idx_onboarding_tem_planos" ON "public"."onboarding_pendente" USING "btree" ("tem_dieta_atual", "tem_treino_atual");



CREATE UNIQUE INDEX "idx_onboarding_unique_active" ON "public"."onboarding_pendente" USING "btree" ("aluno_id") WHERE ("status" = ANY (ARRAY['aguardando_analise'::"public"."status_onboarding", 'em_revisao'::"public"."status_onboarding"]));



CREATE INDEX "idx_payment_transactions_aluno" ON "public"."payment_transactions" USING "btree" ("aluno_id");



CREATE INDEX "idx_payment_transactions_created" ON "public"."payment_transactions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_payment_transactions_external_id" ON "public"."payment_transactions" USING "btree" ("external_transaction_id");



CREATE INDEX "idx_payment_transactions_status" ON "public"."payment_transactions" USING "btree" ("status");



CREATE INDEX "idx_payment_transactions_subscription" ON "public"."payment_transactions" USING "btree" ("subscription_id");



CREATE INDEX "idx_preferences_aluno_id" ON "public"."preferences_old" USING "btree" ("aluno_id");



CREATE INDEX "idx_processed_messages_created" ON "public"."processed_webhook_messages" USING "btree" ("processed_at");



CREATE INDEX "idx_processed_messages_id" ON "public"."processed_webhook_messages" USING "btree" ("message_id");



CREATE INDEX "idx_processed_webhook_messages_status" ON "public"."processed_webhook_messages" USING "btree" ("message_id", "status");



CREATE INDEX "idx_subscriptions_aluno_id" ON "public"."subscriptions" USING "btree" ("aluno_id");



CREATE INDEX "idx_subscriptions_external_id" ON "public"."subscriptions" USING "btree" ("external_subscription_id");



CREATE INDEX "idx_subscriptions_proxima_cobranca" ON "public"."subscriptions" USING "btree" ("data_proxima_cobranca") WHERE (("status")::"text" = 'active'::"text");



CREATE INDEX "idx_subscriptions_status" ON "public"."subscriptions" USING "btree" ("status");



CREATE INDEX "idx_usage_metrics_aluno_id" ON "public"."usage_metrics" USING "btree" ("aluno_id");



CREATE INDEX "idx_usage_metrics_created_at" ON "public"."usage_metrics" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_vw_nutricao_mensal_aluno" ON "public"."vw_nutricao_resumo_mensal" USING "btree" ("aluno_id");



CREATE INDEX "idx_vw_nutricao_mensal_mes" ON "public"."vw_nutricao_resumo_mensal" USING "btree" ("mes_inicio" DESC);



CREATE INDEX "idx_vw_nutricao_semanal_aluno" ON "public"."vw_nutricao_resumo_semanal" USING "btree" ("aluno_id");



CREATE INDEX "idx_vw_nutricao_semanal_semana" ON "public"."vw_nutricao_resumo_semanal" USING "btree" ("semana_inicio" DESC);



CREATE INDEX "idx_vw_treino_diario_aluno" ON "public"."vw_treino_resumo_diario" USING "btree" ("aluno_id");



CREATE INDEX "idx_vw_treino_diario_data" ON "public"."vw_treino_resumo_diario" USING "btree" ("data_treino" DESC);



CREATE INDEX "idx_vw_treino_mensal_aluno" ON "public"."vw_treino_resumo_mensal" USING "btree" ("aluno_id");



CREATE INDEX "idx_vw_treino_mensal_mes" ON "public"."vw_treino_resumo_mensal" USING "btree" ("mes_inicio" DESC);



CREATE INDEX "idx_vw_treino_semanal_aluno" ON "public"."vw_treino_resumo_semanal" USING "btree" ("aluno_id");



CREATE INDEX "idx_vw_treino_semanal_semana" ON "public"."vw_treino_resumo_semanal" USING "btree" ("semana_inicio" DESC);



CREATE INDEX "idx_workout_executions_aluno_data" ON "public"."daily_workout_executions" USING "btree" ("aluno_id", "data_treino" DESC);



CREATE INDEX "idx_workout_executions_created" ON "public"."daily_workout_executions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_workout_executions_program" ON "public"."daily_workout_executions" USING "btree" ("program_workout_id");



CREATE INDEX "idx_workout_plans_active" ON "public"."workout_plans_old" USING "btree" ("aluno_id", "is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_workout_plans_aluno_id" ON "public"."workout_plans_old" USING "btree" ("aluno_id");



CREATE UNIQUE INDEX "idx_workout_plans_one_active_per_aluno" ON "public"."workout_plans_old" USING "btree" ("aluno_id") WHERE ("is_active" = true);



CREATE INDEX "idx_workout_plans_version" ON "public"."workout_plans_old" USING "btree" ("aluno_id", "version" DESC);



CREATE INDEX "idx_workout_programs_profissional" ON "public"."workout_programs" USING "btree" ("criado_por_profissional_id");



CREATE UNIQUE INDEX "unique_active_goal_per_aluno" ON "public"."goals" USING "btree" ("aluno_id") WHERE (("status")::"text" = 'active'::"text");



CREATE UNIQUE INDEX "vw_nutricao_resumo_diario_unique_idx" ON "public"."vw_nutricao_resumo_diario" USING "btree" ("aluno_id", "data_registro");



CREATE OR REPLACE TRIGGER "after_convite_ativado" AFTER UPDATE ON "public"."convites_alunos" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_convite_ativado"();



CREATE OR REPLACE TRIGGER "finalizar_onboarding_ao_vincular_whatsapp" AFTER UPDATE OF "whatsapp" ON "public"."alunos" FOR EACH ROW WHEN (((("old"."whatsapp" IS NULL) OR (("old"."whatsapp")::"text" = ''::"text")) AND (("new"."whatsapp" IS NOT NULL) AND (("new"."whatsapp")::"text" <> ''::"text")))) EXECUTE FUNCTION "public"."marcar_onboarding_concluido"();



CREATE OR REPLACE TRIGGER "handle_prompts_sistema_updated_at" BEFORE UPDATE ON "public"."prompts_sistema" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trigger_achievements_changes" AFTER INSERT OR DELETE ON "public"."achievements" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_body_metrics_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."body_metrics" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_diet_plans_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."diet_plans" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_goals_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."goals" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_onboarding_updated_at" BEFORE UPDATE ON "public"."onboarding_pendente" FOR EACH ROW EXECUTE FUNCTION "public"."update_onboarding_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_preferencias_alimentares_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."preferencias_alimentares" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_preferencias_treino_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."preferencias_treino" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_program_workouts_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."program_workouts" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_saude_e_rotina_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."saude_e_rotina" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_update_funcoes_ia_updated_at" BEFORE UPDATE ON "public"."funcoes_ia" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trigger_validar_profissional" BEFORE INSERT OR UPDATE ON "public"."onboarding_pendente" FOR EACH ROW EXECUTE FUNCTION "public"."validar_profissional_responsavel"();



CREATE OR REPLACE TRIGGER "trigger_workout_exercises_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."workout_exercises" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "trigger_workout_programs_changes" AFTER INSERT OR DELETE OR UPDATE ON "public"."workout_programs" FOR EACH ROW EXECUTE FUNCTION "public"."handle_dynamic_prompt_update"();



CREATE OR REPLACE TRIGGER "update_aluno_profissional_updated_at" BEFORE UPDATE ON "public"."aluno_profissional" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_food_items_updated_at" BEFORE UPDATE ON "public"."food_items" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_workout_executions_updated_at" BEFORE UPDATE ON "public"."daily_workout_executions" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "validate_profissional_role_trigger" BEFORE INSERT OR UPDATE ON "public"."aluno_profissional" FOR EACH ROW EXECUTE FUNCTION "public"."validate_profissional_role"();



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_goal_id_fkey" FOREIGN KEY ("goal_id") REFERENCES "public"."goals"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."aluno_profissional"
    ADD CONSTRAINT "aluno_profissional_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."aluno_profissional"
    ADD CONSTRAINT "aluno_profissional_profissional_id_fkey" FOREIGN KEY ("profissional_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alunos"
    ADD CONSTRAINT "alunos_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."body_metrics"
    ADD CONSTRAINT "body_metrics_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."body_metrics"
    ADD CONSTRAINT "body_metrics_registrado_por_profissional_id_fkey" FOREIGN KEY ("registrado_por_profissional_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."completions_old"
    ADD CONSTRAINT "completions_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."convites_alunos"
    ADD CONSTRAINT "convites_alunos_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."convites_alunos"
    ADD CONSTRAINT "convites_alunos_profissional_id_fkey" FOREIGN KEY ("profissional_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_consumption_history"
    ADD CONSTRAINT "daily_consumption_history_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_workout_executions"
    ADD CONSTRAINT "daily_workout_executions_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_workout_executions"
    ADD CONSTRAINT "daily_workout_executions_program_workout_id_fkey" FOREIGN KEY ("program_workout_id") REFERENCES "public"."program_workouts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_workout_logs"
    ADD CONSTRAINT "daily_workout_logs_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."diet_plans"
    ADD CONSTRAINT "diet_plans_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."diet_plans"
    ADD CONSTRAINT "diet_plans_criado_por_profissional_id_fkey" FOREIGN KEY ("criado_por_profissional_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."dynamic_prompts_old"
    ADD CONSTRAINT "dynamic_prompts_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dynamic_prompts"
    ADD CONSTRAINT "dynamic_prompts_aluno_id_fkey1" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."botoes_ativos"
    ADD CONSTRAINT "fk_botoes_ativos_aluno" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."workout_exercises"
    ADD CONSTRAINT "fk_exercicio_template" FOREIGN KEY ("exercicio_template_id") REFERENCES "public"."exercicios_template"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."goals"
    ADD CONSTRAINT "goals_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."goals"
    ADD CONSTRAINT "goals_criado_por_profissional_id_fkey" FOREIGN KEY ("criado_por_profissional_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."historico_atualizacoes_exercicio"
    ADD CONSTRAINT "historico_atualizacoes_exercicio_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."historico_atualizacoes_exercicio"
    ADD CONSTRAINT "historico_atualizacoes_exercicio_exercicio_id_fkey" FOREIGN KEY ("exercicio_id") REFERENCES "public"."workout_exercises"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."instrucoes_nutricionista"
    ADD CONSTRAINT "instrucoes_nutricionista_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."instrucoes_nutricionista"
    ADD CONSTRAINT "instrucoes_nutricionista_criado_por_profissional_id_fkey" FOREIGN KEY ("criado_por_profissional_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."instrucoes_personal"
    ADD CONSTRAINT "instrucoes_personal_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."instrucoes_personal"
    ADD CONSTRAINT "instrucoes_personal_criado_por_profissional_id_fkey" FOREIGN KEY ("criado_por_profissional_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mensagens_temporarias"
    ADD CONSTRAINT "mensagens_temporarias_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mensagens_temporarias"
    ADD CONSTRAINT "mensagens_temporarias_completion_id_fkey" FOREIGN KEY ("completion_id") REFERENCES "public"."completions_old"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."onboarding_pendente"
    ADD CONSTRAINT "onboarding_pendente_aluno_id_fkey" FOREIGN KEY ("aluno_id") REFERENCES "public"."alunos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."onboarding_pendente"
    ADD CONSTRAINT "onboarding_pendente_aprovado_por_id_fkey" FOREIGN KEY ("aprovado_por_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."onboarding_pendente"
    ADD CONSTRAINT "onboarding_pendente_profissional_responsavel_id_fkey" FOREIGN KEY ("profissional_responsavel_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



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



ALTER TABLE ONLY "public"."workout_programs"
    ADD CONSTRAINT "workout_programs_criado_por_profissional_id_fkey" FOREIGN KEY ("criado_por_profissional_id") REFERENCES "public"."alunos"("id") ON DELETE SET NULL;



CREATE POLICY "Alunos atualizam apenas seus goals" ON "public"."goals" TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Alunos editam seus proprios onboardings" ON "public"."onboarding_pendente" FOR UPDATE TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Alunos gerenciam apenas suas métricas" ON "public"."body_metrics" TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Alunos podem atualizar seus próprios dados" ON "public"."alunos" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "auth_user_id")) WITH CHECK (("auth"."uid"() = "auth_user_id"));



CREATE POLICY "Alunos podem ver seus próprios dados" ON "public"."alunos" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "auth_user_id"));



CREATE POLICY "Alunos veem apenas seus goals" ON "public"."goals" FOR SELECT TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Alunos veem apenas suas métricas" ON "public"."body_metrics" FOR SELECT TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Alunos veem seus proprios onboardings" ON "public"."onboarding_pendente" FOR SELECT TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Profissionais editam seus onboardings pendentes" ON "public"."onboarding_pendente" FOR UPDATE TO "authenticated" USING (("profissional_responsavel_id" = "public"."get_current_aluno_id"())) WITH CHECK (("profissional_responsavel_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Profissionais veem seus onboardings pendentes" ON "public"."onboarding_pendente" FOR SELECT TO "authenticated" USING (("profissional_responsavel_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Qualquer um pode ver perfil de profissionais" ON "public"."alunos" FOR SELECT USING (("role" = ANY (ARRAY['nutricionista'::"public"."user_role", 'personal'::"public"."user_role", 'master'::"public"."user_role", 'dev'::"public"."user_role"])));



CREATE POLICY "Service role can read config" ON "public"."config_sistema" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Service role pode ler funcoes_ia" ON "public"."funcoes_ia" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Service role pode ler prompts_sistema" ON "public"."prompts_sistema" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Usuários podem atualizar sua própria saúde" ON "public"."saude_e_rotina" FOR UPDATE TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Usuários podem criar seu próprio registro" ON "public"."alunos" FOR INSERT TO "authenticated" WITH CHECK (("auth_user_id" = "auth"."uid"()));



CREATE POLICY "Usuários podem criar seu próprio registro de aluno" ON "public"."alunos" FOR INSERT TO "authenticated" WITH CHECK (("auth_user_id" = "auth"."uid"()));



CREATE POLICY "Usuários podem gerenciar seus objetivos" ON "public"."goals" TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Usuários podem gerenciar suas métricas" ON "public"."body_metrics" TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Usuários podem gerenciar suas preferências alimentares" ON "public"."preferencias_alimentares" TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Usuários podem gerenciar suas preferências de treino" ON "public"."preferencias_treino" TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"())) WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Usuários podem inserir sua própria saúde" ON "public"."saude_e_rotina" FOR INSERT TO "authenticated" WITH CHECK (("aluno_id" = "public"."get_current_aluno_id"()));



CREATE POLICY "Usuários podem ver sua própria saúde" ON "public"."saude_e_rotina" FOR SELECT TO "authenticated" USING (("aluno_id" = "public"."get_current_aluno_id"()));



ALTER TABLE "public"."alunos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "alunos_select_own" ON "public"."alunos" FOR SELECT USING (("auth"."uid"() = "auth_user_id"));



ALTER TABLE "public"."body_metrics" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."config_sistema" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."funcoes_ia" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."goals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "instrucoes_nutri_insert_professional" ON "public"."instrucoes_nutricionista" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "instrucoes_nutri_select_own" ON "public"."instrucoes_nutricionista" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."alunos"
  WHERE (("alunos"."id" = "instrucoes_nutricionista"."aluno_id") AND ("alunos"."auth_user_id" = "auth"."uid"())))));



CREATE POLICY "instrucoes_nutri_select_professional" ON "public"."instrucoes_nutricionista" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "instrucoes_nutri_update_professional" ON "public"."instrucoes_nutricionista" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."instrucoes_nutricionista" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."instrucoes_personal" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "instrucoes_personal_insert_professional" ON "public"."instrucoes_personal" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "instrucoes_personal_select_own" ON "public"."instrucoes_personal" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."alunos"
  WHERE (("alunos"."id" = "instrucoes_personal"."aluno_id") AND ("alunos"."auth_user_id" = "auth"."uid"())))));



CREATE POLICY "instrucoes_personal_select_professional" ON "public"."instrucoes_personal" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "instrucoes_personal_update_professional" ON "public"."instrucoes_personal" FOR UPDATE USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."onboarding_pendente" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "onboarding_select_own" ON "public"."onboarding_pendente" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."alunos"
  WHERE (("alunos"."id" = "onboarding_pendente"."aluno_id") AND ("alunos"."auth_user_id" = "auth"."uid"())))));



CREATE POLICY "onboarding_select_professional" ON "public"."onboarding_pendente" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."preferencias_alimentares" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."preferencias_treino" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profissionais_select_alunos" ON "public"."alunos" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."prompts_sistema" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."saude_e_rotina" ENABLE ROW LEVEL SECURITY;




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



GRANT ALL ON FUNCTION "public"."aprovar_onboarding"("p_onboarding_id" "uuid", "p_aprovado_por_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."aprovar_onboarding"("p_onboarding_id" "uuid", "p_aprovado_por_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."aprovar_onboarding"("p_onboarding_id" "uuid", "p_aprovado_por_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_carga_exercicio"("p_exercicio_id" "uuid", "p_aluno_id" "uuid", "p_nova_carga" numeric, "p_whatsapp" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."atualizar_peso_aluno"("p_aluno_id" "uuid", "p_novo_peso" numeric, "p_data_medicao" "date", "p_notas" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_peso_aluno"("p_aluno_id" "uuid", "p_novo_peso" numeric, "p_data_medicao" "date", "p_notas" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_peso_aluno"("p_aluno_id" "uuid", "p_novo_peso" numeric, "p_data_medicao" "date", "p_notas" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_prompt_final_para_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."atualizar_resumo_completo_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."atualizar_resumo_completo_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."atualizar_resumo_completo_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_old_processed_messages"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_old_processed_messages"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_old_processed_messages"() TO "service_role";



GRANT ALL ON FUNCTION "public"."criar_convite_para_aluno"("p_aluno_id" "uuid", "p_profissional_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."criar_convite_para_aluno"("p_aluno_id" "uuid", "p_profissional_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."criar_convite_para_aluno"("p_aluno_id" "uuid", "p_profissional_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cron_rebuild_all_prompts"() TO "anon";
GRANT ALL ON FUNCTION "public"."cron_rebuild_all_prompts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cron_rebuild_all_prompts"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."deletar_usuario_completo"("p_auth_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."deletar_usuario_completo"("p_auth_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."desativar_vinculo_profissional"("p_vinculo_id" "uuid", "p_motivo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."desativar_vinculo_profissional"("p_vinculo_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."desativar_vinculo_profissional"("p_vinculo_id" "uuid", "p_motivo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."enviar_mensagem_ativacao_whatsapp"("p_whatsapp" "text", "p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."enviar_mensagem_ativacao_whatsapp"("p_whatsapp" "text", "p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."enviar_mensagem_ativacao_whatsapp"("p_whatsapp" "text", "p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."extrair_macros_do_texto"("p_texto_alimentos" "text", "p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid", "p_profissional_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid", "p_profissional_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."finalizar_onboarding_aluno"("p_entrada_id" "uuid", "p_profissional_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."gerar_codigo_convite"("p_tipo_profissional" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."gerar_codigo_convite"("p_tipo_profissional" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gerar_codigo_convite"("p_tipo_profissional" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gerar_conquistas_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_aluno_chart_data"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_aluno_chart_data"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_aluno_chart_data"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_aluno_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_aluno_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_aluno_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_diet_for_today"("p_plano_semanal" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_exercicios_template_json"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_exercicios_template_json"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_exercicios_template_json"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_food_items_template"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_food_items_template"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_food_items_template"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_full_workout_program_json"("p_program_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_resumo_treino_para_coach"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_resumo_treino_para_coach"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_resumo_treino_para_coach"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_workout_for_today"("p_program_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_dynamic_prompt_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_dynamic_prompt_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_dynamic_prompt_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."iniciar_novo_plano_de_treino"("p_aluno_id" "uuid", "p_nome_programa" "text", "p_objetivo" "text", "p_frequencia" integer, "p_programas_json" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."iniciar_novo_plano_de_treino"("p_aluno_id" "uuid", "p_nome_programa" "text", "p_objetivo" "text", "p_frequencia" integer, "p_programas_json" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."iniciar_novo_plano_de_treino"("p_aluno_id" "uuid", "p_nome_programa" "text", "p_objetivo" "text", "p_frequencia" integer, "p_programas_json" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."invoke_testar_extracao_edge_function"() TO "anon";
GRANT ALL ON FUNCTION "public"."invoke_testar_extracao_edge_function"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."invoke_testar_extracao_edge_function"() TO "service_role";



GRANT ALL ON FUNCTION "public"."limpar_completions_antigos"() TO "anon";
GRANT ALL ON FUNCTION "public"."limpar_completions_antigos"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."limpar_completions_antigos"() TO "service_role";



GRANT ALL ON FUNCTION "public"."limpar_dados_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."limpar_dados_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."limpar_dados_aluno"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."limpar_mensagens_temporarias"() TO "anon";
GRANT ALL ON FUNCTION "public"."limpar_mensagens_temporarias"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."limpar_mensagens_temporarias"() TO "service_role";



GRANT ALL ON FUNCTION "public"."marcar_onboarding_concluido"() TO "anon";
GRANT ALL ON FUNCTION "public"."marcar_onboarding_concluido"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_onboarding_concluido"() TO "service_role";



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



GRANT ALL ON FUNCTION "public"."rebuild_full_prompt_for_aluno"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rebuild_full_prompt_for_aluno"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rebuild_full_prompt_for_aluno"("p_aluno_id" "uuid") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."refresh_nutricao_views"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_nutricao_views"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_nutricao_views"() TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_execucao_treino"("p_aluno_id" "uuid", "p_nome_treino" "text", "p_descricao_atividade" "text", "p_duracao_minutos" integer, "p_observacoes" "text", "p_data_treino" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_execucao_treino"("p_aluno_id" "uuid", "p_nome_treino" "text", "p_descricao_atividade" "text", "p_duracao_minutos" integer, "p_observacoes" "text", "p_data_treino" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_execucao_treino"("p_aluno_id" "uuid", "p_nome_treino" "text", "p_descricao_atividade" "text", "p_duracao_minutos" integer, "p_observacoes" "text", "p_data_treino" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."rejeitar_onboarding"("p_onboarding_id" "uuid", "p_motivo" "text", "p_rejeitado_por_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rejeitar_onboarding"("p_onboarding_id" "uuid", "p_motivo" "text", "p_rejeitado_por_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rejeitar_onboarding"("p_onboarding_id" "uuid", "p_motivo" "text", "p_rejeitado_por_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_aggregation_and_reset_flag"("p_aluno_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."schedule_aggregation_on_new_message"() TO "anon";
GRANT ALL ON FUNCTION "public"."schedule_aggregation_on_new_message"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."schedule_aggregation_on_new_message"() TO "service_role";



GRANT ALL ON FUNCTION "public"."submeter_onboarding_aluno"("p_aluno_id" "uuid", "p_dados_form" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submeter_onboarding_aluno"("p_aluno_id" "uuid", "p_dados_form" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submeter_onboarding_aluno"("p_aluno_id" "uuid", "p_dados_form" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_profissional_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_profissional_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_profissional_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_whatsapp" "text", "p_profissional_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_whatsapp" "text", "p_profissional_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submeter_onboarding_simplificado"("p_aluno_id" "uuid", "p_tem_dieta_atual" boolean, "p_dieta_atual_texto" "text", "p_tem_treino_atual" boolean, "p_treino_atual_texto" "text", "p_whatsapp" "text", "p_profissional_id" "uuid") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."trigger_convite_ativado"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_convite_ativado"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_convite_ativado"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_onboarding_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_onboarding_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_onboarding_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validar_profissional_responsavel"() TO "anon";
GRANT ALL ON FUNCTION "public"."validar_profissional_responsavel"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validar_profissional_responsavel"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_profissional_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_profissional_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_profissional_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."vincular_aluno_profissional"("p_aluno_id" "uuid", "p_profissional_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."vincular_aluno_profissional"("p_aluno_id" "uuid", "p_profissional_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vincular_aluno_profissional"("p_aluno_id" "uuid", "p_profissional_id" "uuid") TO "service_role";












SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;









GRANT ALL ON TABLE "public"."achievements" TO "anon";
GRANT ALL ON TABLE "public"."achievements" TO "authenticated";
GRANT ALL ON TABLE "public"."achievements" TO "service_role";



GRANT ALL ON TABLE "public"."aluno_profissional" TO "anon";
GRANT ALL ON TABLE "public"."aluno_profissional" TO "authenticated";
GRANT ALL ON TABLE "public"."aluno_profissional" TO "service_role";



GRANT ALL ON TABLE "public"."alunos" TO "anon";
GRANT ALL ON TABLE "public"."alunos" TO "authenticated";
GRANT ALL ON TABLE "public"."alunos" TO "service_role";



GRANT ALL ON TABLE "public"."body_metrics" TO "anon";
GRANT ALL ON TABLE "public"."body_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."body_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."botoes_ativos" TO "anon";
GRANT ALL ON TABLE "public"."botoes_ativos" TO "authenticated";
GRANT ALL ON TABLE "public"."botoes_ativos" TO "service_role";



GRANT ALL ON TABLE "public"."completions_old" TO "anon";
GRANT ALL ON TABLE "public"."completions_old" TO "authenticated";
GRANT ALL ON TABLE "public"."completions_old" TO "service_role";



GRANT ALL ON TABLE "public"."config_sistema" TO "anon";
GRANT ALL ON TABLE "public"."config_sistema" TO "authenticated";
GRANT ALL ON TABLE "public"."config_sistema" TO "service_role";



GRANT ALL ON TABLE "public"."convites_alunos" TO "anon";
GRANT ALL ON TABLE "public"."convites_alunos" TO "authenticated";
GRANT ALL ON TABLE "public"."convites_alunos" TO "service_role";



GRANT ALL ON TABLE "public"."daily_consumption_history" TO "anon";
GRANT ALL ON TABLE "public"."daily_consumption_history" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_consumption_history" TO "service_role";



GRANT ALL ON TABLE "public"."daily_workout_executions" TO "anon";
GRANT ALL ON TABLE "public"."daily_workout_executions" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_workout_executions" TO "service_role";



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



GRANT ALL ON TABLE "public"."exercicios_template" TO "anon";
GRANT ALL ON TABLE "public"."exercicios_template" TO "authenticated";
GRANT ALL ON TABLE "public"."exercicios_template" TO "service_role";



GRANT ALL ON SEQUENCE "public"."exercicios_template_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."exercicios_template_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."exercicios_template_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."food_items" TO "anon";
GRANT ALL ON TABLE "public"."food_items" TO "authenticated";
GRANT ALL ON TABLE "public"."food_items" TO "service_role";



GRANT ALL ON TABLE "public"."funcoes_ia" TO "anon";
GRANT ALL ON TABLE "public"."funcoes_ia" TO "authenticated";
GRANT ALL ON TABLE "public"."funcoes_ia" TO "service_role";



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



GRANT ALL ON TABLE "public"."onboarding_pendente" TO "anon";
GRANT ALL ON TABLE "public"."onboarding_pendente" TO "authenticated";
GRANT ALL ON TABLE "public"."onboarding_pendente" TO "service_role";



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



GRANT ALL ON TABLE "public"."prompts_sistema" TO "anon";
GRANT ALL ON TABLE "public"."prompts_sistema" TO "authenticated";
GRANT ALL ON TABLE "public"."prompts_sistema" TO "service_role";



GRANT ALL ON TABLE "public"."saude_e_rotina" TO "anon";
GRANT ALL ON TABLE "public"."saude_e_rotina" TO "authenticated";
GRANT ALL ON TABLE "public"."saude_e_rotina" TO "service_role";



GRANT ALL ON TABLE "public"."subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."usage_metrics" TO "anon";
GRANT ALL ON TABLE "public"."usage_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."usage_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."vw_aluno_completo" TO "anon";
GRANT ALL ON TABLE "public"."vw_aluno_completo" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_aluno_completo" TO "service_role";



GRANT ALL ON TABLE "public"."vw_alunos_por_profissional" TO "anon";
GRANT ALL ON TABLE "public"."vw_alunos_por_profissional" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_alunos_por_profissional" TO "service_role";



GRANT ALL ON TABLE "public"."vw_alunos_sem_profissional" TO "anon";
GRANT ALL ON TABLE "public"."vw_alunos_sem_profissional" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_alunos_sem_profissional" TO "service_role";



GRANT ALL ON TABLE "public"."vw_completions_aguardando_processamento" TO "anon";
GRANT ALL ON TABLE "public"."vw_completions_aguardando_processamento" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_completions_aguardando_processamento" TO "service_role";



GRANT ALL ON TABLE "public"."vw_mensagens_aguardando_agregacao" TO "anon";
GRANT ALL ON TABLE "public"."vw_mensagens_aguardando_agregacao" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_mensagens_aguardando_agregacao" TO "service_role";



GRANT ALL ON TABLE "public"."vw_metricas_diarias_por_aluno" TO "anon";
GRANT ALL ON TABLE "public"."vw_metricas_diarias_por_aluno" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_metricas_diarias_por_aluno" TO "service_role";



GRANT ALL ON TABLE "public"."vw_metricas_hoje_por_aluno" TO "anon";
GRANT ALL ON TABLE "public"."vw_metricas_hoje_por_aluno" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_metricas_hoje_por_aluno" TO "service_role";



GRANT ALL ON TABLE "public"."vw_nutricao_hoje_por_aluno" TO "anon";
GRANT ALL ON TABLE "public"."vw_nutricao_hoje_por_aluno" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_nutricao_hoje_por_aluno" TO "service_role";



GRANT ALL ON TABLE "public"."vw_nutricao_resumo_diario" TO "anon";
GRANT ALL ON TABLE "public"."vw_nutricao_resumo_diario" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_nutricao_resumo_diario" TO "service_role";



GRANT ALL ON TABLE "public"."vw_nutricao_resumo_mensal" TO "anon";
GRANT ALL ON TABLE "public"."vw_nutricao_resumo_mensal" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_nutricao_resumo_mensal" TO "service_role";



GRANT ALL ON TABLE "public"."vw_nutricao_resumo_semanal" TO "anon";
GRANT ALL ON TABLE "public"."vw_nutricao_resumo_semanal" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_nutricao_resumo_semanal" TO "service_role";



GRANT ALL ON TABLE "public"."vw_perfil_completo_aluno" TO "anon";
GRANT ALL ON TABLE "public"."vw_perfil_completo_aluno" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_perfil_completo_aluno" TO "service_role";



GRANT ALL ON TABLE "public"."vw_teste_semana_atual" TO "anon";
GRANT ALL ON TABLE "public"."vw_teste_semana_atual" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_teste_semana_atual" TO "service_role";



GRANT ALL ON TABLE "public"."workout_programs" TO "anon";
GRANT ALL ON TABLE "public"."workout_programs" TO "authenticated";
GRANT ALL ON TABLE "public"."workout_programs" TO "service_role";



GRANT ALL ON TABLE "public"."vw_treino_resumo_diario" TO "anon";
GRANT ALL ON TABLE "public"."vw_treino_resumo_diario" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_treino_resumo_diario" TO "service_role";



GRANT ALL ON TABLE "public"."vw_treino_resumo_mensal" TO "anon";
GRANT ALL ON TABLE "public"."vw_treino_resumo_mensal" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_treino_resumo_mensal" TO "service_role";



GRANT ALL ON TABLE "public"."vw_treino_resumo_semanal" TO "anon";
GRANT ALL ON TABLE "public"."vw_treino_resumo_semanal" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_treino_resumo_semanal" TO "service_role";



GRANT ALL ON TABLE "public"."workout_exercises" TO "anon";
GRANT ALL ON TABLE "public"."workout_exercises" TO "authenticated";
GRANT ALL ON TABLE "public"."workout_exercises" TO "service_role";



GRANT ALL ON TABLE "public"."workout_plans_old" TO "anon";
GRANT ALL ON TABLE "public"."workout_plans_old" TO "authenticated";
GRANT ALL ON TABLE "public"."workout_plans_old" TO "service_role";









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






























\unrestrict ghtMjOwdpAceXnvldrhCdNvKsyVnFRES8ZRcWvaUutPBxuSw3aDCTfu3evH0arv

RESET ALL;
