output "vm_claude_instance_id" {
  description = "EC2 instance ID for Claude VM — use with SSM Session Manager"
  value       = aws_instance.claude.id
}

output "vm_openai_instance_id" {
  description = "EC2 instance ID for OpenAI VM"
  value       = aws_instance.openai.id
}

output "vm_ollama_instance_id" {
  description = "EC2 instance ID for Ollama VM"
  value       = aws_instance.ollama.id
}

output "vm_deepseek_instance_id" {
  description = "EC2 instance ID for Deepseek VM"
  value       = aws_instance.deepseek.id
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "inbox_url" {
  description = "Static inbox site URL"
  value       = var.inbox_site_url
}
