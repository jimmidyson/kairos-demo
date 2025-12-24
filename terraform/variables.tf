variable "cluster_name" {
  type = string
}
variable "subnet_name" {
  type = string
}
variable "vm_name" {
  type = string
  default = ""
}
variable "image_name" {
  type = string
  default = ""
}

variable "iso_file" {
  type = string
  description = "The name of the ISO file to upload"
}
