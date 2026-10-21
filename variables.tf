variable "region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "max_receive_count" {
  description = "Intentos antes de mandar un mensaje a la dead-letter queue"
  type        = number
  default     = 3
}