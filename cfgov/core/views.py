import logging

from django.core.exceptions import ImproperlyConfigured
from django.http import Http404, JsonResponse
from django.shortcuts import redirect
from django.utils.translation import activate, get_language
from django.views.decorators.http import require_http_methods
from django.views.generic import TemplateView
from django.views.generic.edit import FormMixin

from core.forms import ExternalURLForm
from core.govdelivery import get_govdelivery_api
from core.utils import extract_answers_from_request


logger = logging.getLogger(__name__)

REQUIRED_PARAMS_GOVDELIVERY = ["email", "code"]


@require_http_methods(["POST"])
def govdelivery_subscribe(request):
    """
    View that checks to see if the request is AJAX, attempts to subscribe
    the user, then either redirects to an error/success page (non-AJAX) or
    in the case of AJAX, returns some JSON to tell the front-end.
    """
    is_ajax = request.is_ajax()
    if is_ajax:
        passing_response = JsonResponse({"result": "pass"})
        failing_response = JsonResponse({"result": "fail"})
    else:
        passing_response = redirect("govdelivery:success")
        failing_response = redirect("govdelivery:server_error")
    for required_param in REQUIRED_PARAMS_GOVDELIVERY:
        if required_param not in request.POST or not request.POST.get(
            required_param
        ):
            return (
                failing_response
                if is_ajax
                else redirect("govdelivery:user_error")
            )
    email_address = request.POST["email"]
    codes = request.POST.getlist("code")

    gd = get_govdelivery_api()
    try:
        subscription_response = gd.set_subscriber_topics(
            email_address, codes, send_notifications=True
        )
        if subscription_response.status_code != 200:
            return failing_response
    except Exception:
        return failing_response
    answers = extract_answers_from_request(request)
    for question_id, answer_text in answers:
        gd.set_subscriber_answers_to_question(
            email_address, question_id, answer_text
        )
    return passing_response


class ExternalURLNoticeView(FormMixin, TemplateView):
    template_name = "external-site/index.html"
    form_class = ExternalURLForm

    def dispatch(self, *args, **kwargs):
        return super().dispatch(*args, **kwargs)

    def get_form_kwargs(self):
        kwargs = super().get_form_kwargs()

        if self.request.method == "GET":
            kwargs["data"] = self.request.GET

        return kwargs

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)

        form = self.get_form()
        context["form"] = form

        return context

    def get(self, request):
        form = self.get_form()

        if not form.is_valid():
            raise Http404(
                "URL invalid, not whitelisted, or signature validation failed"
            )

        return super().get(request)


class TranslatedTemplateView(TemplateView):
    """A TemplateView that will activate a language for translation.
    It takes a "language" argument (default: en), activates that language,
    and adds the 'current_language' to the template context."""

    language = "en"

    def get_context_data(self, **kwargs):
        activate(self.language)
        context = super().get_context_data(**kwargs)
        context["current_language"] = get_language()
        return context


class CacheTaggedTemplateView(TemplateView):
    """A TemplateView that responds with an `Edge-Cache-Tag` header.
    The `Edge-Cache-Tag` header will contain the value of the `cache_tag`
    argument provided to this view.
    """

    cache_tag = None

    def dispatch(self, *args, **kwargs):
        response = super().dispatch(*args, **kwargs)
        response["Edge-Cache-Tag"] = self.get_cache_tag()
        return response

    def get_cache_tag(self):
        if self.cache_tag is None:
            raise ImproperlyConfigured(
                "CacheTaggedTemplateView requires either a definition of "
                "'cache_tag' or an implementation of 'get_cache_tag()'"
            )
        return self.cache_tag
