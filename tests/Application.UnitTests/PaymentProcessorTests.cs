using System.Text.Json;
using eShop.EventBus.Abstractions;
using eShop.PaymentProcessor;
using eShop.PaymentProcessor.IntegrationEvents.EventHandling;
using eShop.PaymentProcessor.IntegrationEvents.Events;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using ConsumerEvent = eShop.Ordering.API.Application.IntegrationEvents.Events.OrderPaymentSucceededIntegrationEvent;
using ProducerEvent = eShop.PaymentProcessor.IntegrationEvents.Events.OrderPaymentSucceededIntegrationEvent;

namespace eShop.Application.UnitTests;

[TestClass]
public class PaymentProcessorTests
{
    [TestMethod]
    [DataRow(true)]
    [DataRow(false)]
    public async Task PublishesConfiguredPaymentOutcome(bool paymentSucceeded)
    {
        var eventBus = Substitute.For<IEventBus>();
        var options = Substitute.For<IOptionsMonitor<PaymentOptions>>();
        options.CurrentValue.Returns(new PaymentOptions { PaymentSucceeded = paymentSucceeded });
        var handler = new OrderStatusChangedToStockConfirmedIntegrationEventHandler(
            eventBus,
            options,
            NullLogger<OrderStatusChangedToStockConfirmedIntegrationEventHandler>.Instance);

        await handler.Handle(new OrderStatusChangedToStockConfirmedIntegrationEvent(42));

        if (paymentSucceeded)
        {
            await eventBus.Received(1).PublishAsync(
                Arg.Is<OrderPaymentSucceededIntegrationEvent>(e => e.OrderId == 42));
            await eventBus.DidNotReceive().PublishAsync(Arg.Any<OrderPaymentFailedIntegrationEvent>());
        }
        else
        {
            await eventBus.Received(1).PublishAsync(
                Arg.Is<OrderPaymentFailedIntegrationEvent>(e => e.OrderId == 42));
            await eventBus.DidNotReceive().PublishAsync(Arg.Any<OrderPaymentSucceededIntegrationEvent>());
        }
    }

    [TestMethod]
    public void OrderPaymentSucceededEventSerializesToTheShapeOrderingExpects()
    {
        var options = new EventBusSubscriptionInfo().JsonSerializerOptions;

        var json = JsonSerializer.SerializeToUtf8Bytes(new ProducerEvent(42), typeof(ProducerEvent), options);

        using (var doc = JsonDocument.Parse(json))
        {
            Assert.IsTrue(doc.RootElement.TryGetProperty("OrderId", out var orderId));
            Assert.AreEqual(42, orderId.GetInt32());
            Assert.IsFalse(doc.RootElement.TryGetProperty("OrderNumber", out _));
        }

        var consumed = (ConsumerEvent?)JsonSerializer.Deserialize(json, typeof(ConsumerEvent), options);
        Assert.IsNotNull(consumed);
        Assert.AreEqual(42, consumed.OrderId);
    }
}
