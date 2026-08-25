#!/usr/bin/env bash
# Roda automaticamente quando o LocalStack fica pronto (docker-compose up).
# Cria as filas SQS + DLQ do NotificationsAPI e, se o zip da Lambda já tiver
# sido gerado (veja FCG_Notificacoes/package-lambda.ps1), registra as duas
# funções e liga o Event Source Mapping — o trigger direto que substitui o
# container que rodava continuamente.
set -euo pipefail

REGION="us-east-1"
ROLE_ARN="arn:aws:iam::000000000000:role/lambda-role"
ZIP_FILE="/opt/lambda-artifacts/notificacoes.zip"

create_queue_with_dlq() {
  local queue_name="$1"
  local dlq_name="${queue_name}-dlq"
  local dlq_url dlq_arn attrs_file queue_url

  dlq_url=$(awslocal sqs create-queue --queue-name "$dlq_name" --region "$REGION" --query 'QueueUrl' --output text)
  dlq_arn=$(awslocal sqs get-queue-attributes --queue-url "$dlq_url" --attribute-names QueueArn --region "$REGION" --query 'Attributes.QueueArn' --output text)

  attrs_file="/tmp/${queue_name}-attrs.json"
  cat > "$attrs_file" <<JSON
{
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"${dlq_arn}\",\"maxReceiveCount\":\"3\"}"
}
JSON

  queue_url=$(awslocal sqs create-queue --queue-name "$queue_name" --region "$REGION" --attributes "file://$attrs_file" --query 'QueueUrl' --output text)
  awslocal sqs get-queue-attributes --queue-url "$queue_url" --attribute-names QueueArn --region "$REGION" --query 'Attributes.QueueArn' --output text
}

echo "[init] Criando filas SQS do NotificationsAPI..."
user_created_arn=$(create_queue_with_dlq "user-created")
payment_arn=$(create_queue_with_dlq "payment-processed-notificacoes")
echo "[init] Filas prontas: user-created, payment-processed-notificacoes (+ *-dlq)."

if [ -f "$ZIP_FILE" ]; then
  echo "[init] Registrando funções Lambda a partir de $ZIP_FILE..."

  awslocal lambda create-function \
    --function-name notificacoes-usuario-criado \
    --runtime dotnet8 \
    --handler "FCG.Worker::FCG.Worker.SqsFunction::UsuarioCriadoHandler" \
    --zip-file "fileb://$ZIP_FILE" \
    --role "$ROLE_ARN" \
    --timeout 30 \
    --region "$REGION"

  awslocal lambda create-function \
    --function-name notificacoes-pagamento-processado \
    --runtime dotnet8 \
    --handler "FCG.Worker::FCG.Worker.SqsFunction::PagamentoProcessadoHandler" \
    --zip-file "fileb://$ZIP_FILE" \
    --role "$ROLE_ARN" \
    --timeout 30 \
    --region "$REGION"

  awslocal lambda wait function-active --function-name notificacoes-usuario-criado --region "$REGION"
  awslocal lambda wait function-active --function-name notificacoes-pagamento-processado --region "$REGION"

  awslocal lambda create-event-source-mapping \
    --function-name notificacoes-usuario-criado \
    --event-source-arn "$user_created_arn" \
    --batch-size 5 \
    --function-response-types ReportBatchItemFailures \
    --region "$REGION"

  awslocal lambda create-event-source-mapping \
    --function-name notificacoes-pagamento-processado \
    --event-source-arn "$payment_arn" \
    --batch-size 5 \
    --function-response-types ReportBatchItemFailures \
    --region "$REGION"

  echo "[init] Lambdas registradas e Event Source Mappings ativos — trigger direto pronto."
else
  echo "[init] AVISO: $ZIP_FILE não encontrado."
  echo "[init] Rode FCG_Notificacoes/package-lambda.ps1 e reinicie o LocalStack (docker-compose restart localstack) para registrar as funções."
fi
