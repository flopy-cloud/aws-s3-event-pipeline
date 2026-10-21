import json
import os
from urllib.parse import unquote_plus

import boto3

dynamodb = boto3.resource("dynamodb")
tabla = dynamodb.Table(os.environ["TABLE_NAME"])


def lambda_handler(event, context):
    fallidos = []

    for mensaje in event["Records"]:
        try:
            cuerpo = json.loads(mensaje["body"])

            # S3 manda un mensaje de prueba al configurar la notificación
            if "Records" not in cuerpo:
                print("Mensaje de prueba de S3, se ignora")
                continue

            for registro in cuerpo["Records"]:
                clave = unquote_plus(registro["s3"]["object"]["key"])

                # Para probar la dead-letter queue: los archivos que
                # empiezan con "error-" fallan a propósito
                if clave.startswith("error-"):
                    raise ValueError(f"Falla simulada para {clave}")

                tabla.put_item(
                    Item={
                        "object_key": clave,
                        "event_time": registro["eventTime"],
                        "bucket": registro["s3"]["bucket"]["name"],
                        "size_bytes": registro["s3"]["object"]["size"],
                        "event_name": registro["eventName"],
                    }
                )
                print(f"Registrado: {clave}")

        except Exception as e:
            print(f"Error con el mensaje {mensaje['messageId']}: {e}")
            fallidos.append({"itemIdentifier": mensaje["messageId"]})

    # Solo se reintentan los mensajes que fallaron
    return {"batchItemFailures": fallidos}