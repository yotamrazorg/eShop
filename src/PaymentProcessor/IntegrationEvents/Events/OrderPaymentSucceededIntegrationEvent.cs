namespace eShop.PaymentProcessor.IntegrationEvents.Events;

public record OrderPaymentSucceededIntegrationEvent([property: System.Text.Json.Serialization.JsonPropertyName("OrderNumber")] int OrderId) : IntegrationEvent;
