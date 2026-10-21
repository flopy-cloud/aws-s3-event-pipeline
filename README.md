# # Pipeline de eventos con S3, SQS, Lambda y DynamoDB

## Objetivo
Procesar archivos de forma automática y sin perder ninguno: cada vez que se sube un archivo a S3, se registra en una base de datos. Si el procesamiento falla, el mensaje no se pierde, sino que queda guardado en una cola de errores (dead-letter queue).

## Arquitectura
- **S3:** bucket privado, con el acceso público bloqueado. Avisa a SQS cada vez que se crea un archivo.
- **SQS (cola principal):** recibe los avisos de S3 y desacopla la subida del procesamiento.
- **Lambda (Python 3.13):** lee los mensajes de la cola y guarda en DynamoDB el nombre del archivo, su tamaño, el bucket y la fecha del evento.
- **DynamoDB:** tabla `event-pipeline-archivos` en modo bajo demanda (pago por uso).
- **SQS (dead-letter queue):** recibe los mensajes que fallan 3 veces seguidas.
- **IAM:** rol con permisos mínimos. La Lambda solo puede leer de esa cola, escribir en esa tabla y generar logs.

Toda la infraestructura está definida con **Terraform** en la región `us-east-1`.

## Cómo funciona
1. Se sube un archivo al bucket.
2. S3 envía un evento a la cola principal.
3. La Lambda procesa el mensaje y registra el archivo en DynamoDB.
4. Si la Lambda falla, el mensaje vuelve a la cola y se reintenta. Después de 3 intentos pasa a la dead-letter queue, donde se conserva 14 días para revisarlo.

La Lambda informa a SQS qué mensajes fallaron, así que solo se reintentan esos y no todo el lote.

## Cómo usarlo
```bash
terraform init
terraform plan
terraform apply
```

Probar el camino normal:
```bash
echo "hola" > prueba1.txt
aws s3 cp prueba1.txt s3://$(terraform output -raw bucket_name)/
aws dynamodb scan --table-name $(terraform output -raw table_name) --region us-east-1
```

Probar la dead-letter queue (los archivos cuyo nombre empieza con `error-` fallan a propósito):
```bash
echo "x" > error-prueba.txt
aws s3 cp error-prueba.txt s3://$(terraform output -raw bucket_name)/
```

Para eliminar todo:
```bash
terraform destroy
```

## Resultados

### Despliegue con Terraform
<img width="513" height="39" alt="Captura de pantalla de 2026-10-21 18-26-02" src="https://github.com/user-attachments/assets/fef365a7-f85f-463f-954d-d5e71ff0b18e" />


### Archivos subidos al bucket
<img width="1424" height="92" alt="Captura de pantalla de 2026-10-21 18-34-46" src="https://github.com/user-attachments/assets/98708c6c-aac5-4849-9ce9-0f216abb28e4" />


### Archivo registrado en DynamoDB

<img width="1251" height="364" alt="Captura de pantalla de 2026-10-21 18-31-45" src="https://github.com/user-attachments/assets/6e5ce315-ce6d-43b7-bfd8-583d43257e20" />


### Mensaje fallido en la dead-letter queue
<img width="1325" height="72" alt="Captura de pantalla de 2026-10-21 18-37-57" src="https://github.com/user-attachments/assets/16b30483-9a38-4899-ba52-1b3b563d44e2" />


## Qué aprendí
- Una cola entre S3 y la Lambda evita perder eventos si el procesamiento falla o se demora.
- La dead-letter queue guarda los mensajes problemáticos para revisarlos después, en lugar de descartarlos o reintentarlos para siempre.
- La política de la cola tiene que permitir explícitamente que S3 escriba en ella, y solo desde ese bucket.
- Con `ReportBatchItemFailures` solo se reintentan los mensajes que fallaron, no todo el lote.

## Costo
Prácticamente cero. S3, SQS, Lambda y DynamoDB bajo demanda entran en el free tier para este volumen. Destruí la infraestructura después de las pruebas.aws-s3-event-pipeline
