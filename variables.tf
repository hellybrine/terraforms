variable "project_name" {
  description = "Name of the project (used for resource naming)"
  type        = string
  default     = "image-resizer"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "default_resized_width" {
  description = "Default width for resized images in pixels"
  type        = number
  default     = 800
}

variable "default_resized_height" {
  description = "Default height for resized images in pixels"
  type        = number
  default     = 600
}
